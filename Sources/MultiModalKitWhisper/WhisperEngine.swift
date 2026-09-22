import AVFoundation
import MultiModalKit
import WhisperKit

/// The second engine (D-017, D-023): Whisper, on-device via WhisperKit's
/// CoreML pipeline, behind the same seam as everything else. The session
/// cannot tell it from the Apple engine or the scripted one — which is the
/// whole point, and the conformance kit proves it.
///
/// This engine tells the truth about itself (AC-38): it emits **no**
/// partials, it wants the **whole utterance**, and it wants **16 kHz**. The
/// session already knows what to do with that shape (D-024): a decode may
/// finish after the next utterance began, and its final survives, tagged.
///
/// An actor on purpose: WhisperKit's pipeline is one mutable object, and
/// several settling decodes may exist at once (D-024) — actor isolation
/// serializes them without a single manual lock.
public actor WhisperEngine: TranscriptionEngine, ModelBacked {
    public nonisolated let capabilities = EngineCapabilities(
        emitsPartials: false,
        wantsWholeUtterance: true,
        requiredSampleRate: 16_000
    )

    private let model: String
    private nonisolated let diagnostics: PipelineDiagnostics?
    /// The loaded models, behind the shape that gets this right.
    ///
    /// This was a hand-written `pipeline` + `loadBusy` + `loadWaiters`, the
    /// same trio the neural voice and the local mind each wrote separately.
    /// The pattern has been wrong five times in this project (D-051), and
    /// most recently wrong HERE in a way no test could see: one resume where
    /// all were needed, stranding every caller after the second. Found by a
    /// three-caller test against `Retirable` that HUNG, fixed in three
    /// places by inspection — and fixing by inspection is what this
    /// conversion ends. One implementation, one set of tests.
    private let held = Retirable<LoadedWhisper>()

    /// `WhisperKit` IS NOT `Sendable`, and we do not get to change that.
    ///
    /// `Retirable` holds a `Sendable` resource, so the vendor's class needs
    /// a box — and an `@unchecked Sendable` box is an exception that owes a
    /// proof (§4.1). Here it is, in three lines:
    ///
    ///   1. the box is CREATED inside the holder's build closure and handed
    ///      straight to the holder — nobody else ever sees that reference;
    ///   2. the holder stores it in an actor, and hands it out only from
    ///      actor-isolated code, so there is one reader at a time;
    ///   3. every use is inside `WhisperEngine`, itself an actor, and
    ///      `decode` additionally serialises with its own busy flag.
    ///
    /// So the box crosses a boundary exactly once, as sole ownership, and is
    /// confined afterwards. It is the same shape as `NeuralVoiceRun`'s
    /// `@unchecked Sendable`, and narrower.
    private struct LoadedWhisper: @unchecked Sendable {
        let kit: WhisperKit
    }

    /// THE LANGUAGE HINT (4u, AC-212, F-1 = A). `nil` leaves WhisperKit to
    /// its default; a BCP-47 code such as `"ar"` or `"de"` tells the decoder
    /// which language it is hearing instead of letting it guess from the
    /// first seconds — and on the multilingual `base`/`small` models a
    /// wrong guess is a whole utterance transcribed into the wrong script.
    /// Policy: the APP chooses (D-027), because only the app knows what
    /// the person picked.
    public nonisolated let language: String?

    /// Where this engine's bytes come from, and what moves them (5a).
    /// The library's Hub and shared background downloader by default; a
    /// test hands in a loopback server and a downloader of its own.
    ///
    /// FULLY QUALIFIED, because WhisperKit ships an `ModelDownloader` of
    /// its own (`ArgmaxCore`) and both are in scope here. The vendor's
    /// is the one this milestone replaced; naming the module says which
    /// is meant, in the file where the two meet.
    private nonisolated let source: WhisperSource
    private nonisolated let downloader: MultiModalKit.ModelDownloader

    public init(model: String = "base", language: String? = nil,
                diagnostics: PipelineDiagnostics? = nil) {
        self.init(model: model, language: language, diagnostics: diagnostics,
                  source: .hub, downloader: .shared)
    }

    /// The tests' door (5a): two small files over a loopback server
    /// prove what 142 MB would otherwise have to.
    init(model: String, language: String?, diagnostics: PipelineDiagnostics?,
         source: WhisperSource, downloader: MultiModalKit.ModelDownloader) {
        self.language = language
        self.model = model
        self.diagnostics = diagnostics
        self.source = source
        self.downloader = downloader
    }

    /// This engine's variant, its two folders — read by the live size
    /// row, which asks the real repositories what they hold today.
    nonisolated var modelName: String { model }
    nonisolated var modelFolderURL: URL { localModelFolder }
    nonisolated var tokenizerFolderURL: URL { localTokenizerFolder }

    /// Every path this variant's install touches.
    private nonisolated var catalog: WhisperCatalog {
        WhisperCatalog(variant: model, source: source,
                       modelFolder: localModelFolder, tokenizerFolder: localTokenizerFolder)
    }

    /// WhisperKit's default hub location for this model, on this device.
    private nonisolated var localModelFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
            .appending(path: "openai_whisper-\(model)")
    }

    /// WhisperKit's default cache for the tokenizer — a SEPARATE asset from
    /// the model, downloaded alongside it on first install.
    private nonisolated var localTokenizerFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models/openai")
            .appending(path: "whisper-\(model)")
    }

    /// Honest disk check against WhisperKit's default hub locations — no
    /// download is ever triggered by asking.
    ///
    /// "Installed" means OFFLINE-CAPABLE, and that takes more than the model:
    /// the source audit showed the tokenizer load is local-FIRST but not
    /// local-ONLY — if its two cache files are missing, WhisperKit silently
    /// falls back to a Hugging Face download. So this check requires all the
    /// assets a zero-network start needs. Missing tokenizer files mean "not
    /// installed" (download again), never a silent ping.
    public nonisolated func modelInstalled() async -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: localModelFolder.path)
        guard contents?.isEmpty == false else { return false }
        let files = FileManager.default
        return files.fileExists(atPath: localTokenizerFolder.appending(path: "tokenizer.json").path)
            && files.fileExists(atPath: localTokenizerFolder.appending(path: "tokenizer_config.json").path)
    }

    /// Downloads (~142 MB for `base`) and loads the pipeline. Idempotent;
    /// the download half is skipped when the model is on disk.
    public func ensureModel() async throws {
        try await ensureModel(progress: { _ in })
    }

    /// The same work, with a byte fraction over BOTH repositories'
    /// files — 5a's door, and the diet app's ask (AC-291).
    ///
    /// IT LOADS TOO, the rule `KokoroVoice` paid for: two doors into one
    /// room must leave the room in the same state. `ensureModel()` has
    /// always loaded the pipeline here, so this one does as well — the
    /// fraction reaches `1.0` when the bytes are placed, and the load
    /// follows it. `download(progress:)` is the same transfer WITHOUT
    /// the load, the shape the mind already has.
    public func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(progress: progress)
        _ = try await loadedPipeline()
    }

    /// The bytes, and nothing else: both repositories' files fetched and
    /// put in place, reporting one fraction over all of them. Idempotent
    /// — an installed variant says `1.0` once and asks the network
    /// nothing (AC-291).
    ///
    /// SINCE 5a THE BYTES ARE THIS LIBRARY'S (D-114 F-3 = A): two
    /// requests list the model and tokenizer repositories,
    /// `ModelDownloader` moves the files into scratch folders on the
    /// background session — so the transfer goes on while the app is
    /// suspended or dead — and both scratches are moved into place only
    /// when every file is complete. A stopped transfer keeps its scratch
    /// and resume data, and the next call resumes (F-4 = A). Before 5a
    /// the vendor fetched, in the foreground, with no number to show and
    /// nothing to resume.
    ///
    /// THE TOKENIZER IS PART OF THE DOWNLOAD, not an afterthought: the
    /// vendor's tokenizer load is local-FIRST but not local-ONLY, so a
    /// model fetched without it would load by quietly reaching Hugging
    /// Face. "Installed" has meant offline-capable here since the
    /// Whisper audit, and this is what makes that true at the source.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard await !modelInstalled() else {
            progress(1.0)
            return
        }
        let catalog = catalog
        let listing = try await catalog.list()
        try listing.write(to: catalog.listingFile)
        try await downloader.transfer(catalog.plan(from: listing), progress: progress)
        try catalog.place()
    }

    /// What `ensureModel` will download, without the network (AC-294,
    /// F-5 = A): the measured size of a variant this library names, or
    /// the listing this device made, or `nil`. The library chose both
    /// repositories, so the pinned numbers are honest here in a way the
    /// mind's cannot be — and a variant nobody measured gets no guess.
    public nonisolated func expectedDownloadBytes() -> Int64? {
        WhisperSizes.measured[model] ?? WhisperListing.read(from: catalog.listingFile)?.totalBytes
    }

    /// Retires the loaded pipeline and removes exactly what this
    /// variant's `ensureModel` wrote (AC-295): its model folder, its
    /// tokenizer folder, both scratches, the resume data in them and the
    /// listing — a transfer in flight is stopped first.
    ///
    /// ANOTHER VARIANT'S FOLDERS STAY, which is the whole care here:
    /// `base` and `small` live side by side under one hub directory, and
    /// the vendor's `huggingface/` tree holds other models still — the
    /// diet app would not delete Whisper at all for exactly this reason.
    /// Nothing above `openai_whisper-<variant>` is touched.
    ///
    /// - Throws: `DownloadFailure.couldNotPlace` naming what could not be
    ///   removed, so a screen can say why `modelInstalled()` still reads
    ///   true.
    public func deleteModel() async throws {
        let catalog = catalog
        await held.retire()
        isWarmed = false
        if let listing = WhisperListing.read(from: catalog.listingFile) {
            await downloader.discard(catalog.plan(from: listing))
        }
        let files = FileManager.default
        var failures: [String] = []
        for url in [catalog.modelFolder, catalog.tokenizerFolder,
                    catalog.modelScratch, catalog.tokenizerScratch, catalog.listingFile]
        where files.fileExists(atPath: url.path) {
            do {
                try files.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(String(describing: error))")
            }
        }
        guard failures.isEmpty else {
            throw DownloadFailure.couldNotPlace(file: model, failures.joined(separator: " · "))
        }
    }

    private var isWarmed = false

    /// Prewarms the CoreML models and compiles the Apple Neural Engine (ANE)
    /// execution graph off-turn so Turn 1 does not pay the 1.5–2.5s compilation pause.
    ///
    /// Nonisolated and silent by design: matches `LocalMind.prewarm()` and
    /// `AppleReplyGenerator.prewarm()`. Safe to call at launch or when selecting Whisper.
    public nonisolated func prewarm() {
        Task { await self.startPrewarm() }
    }

    func startPrewarm() async {
        guard !isWarmed else { return }
        guard await modelInstalled() else { return }
        isWarmed = true
        let dummy = [Float](repeating: 0, count: 8_000)
        do {
            _ = try await self.decode(dummy)
        } catch {
            isWarmed = false
        }
    }

    public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun {
        // Ask the holder whether the models are already resident, rather
        // than a stored property it now owns. Same meaning, one source.
        if await !held.isResident {
            guard await modelInstalled() else {
                throw TranscriptionFailure.modelNotInstalled
            }
        }
        let pipeline = try await loadedPipeline()
        _ = pipeline   // loaded and cached; the run reaches it through decode(_:)

        guard let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                channels: AVAudioChannelCount(format.channels), interleaved: false),
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscriptionFailure.audioFormatRejected
        }
        return WhisperRun(engine: self, converter: converter, sourceFormat: source, targetFormat: target)
    }

    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    /// One decode at a time — ENFORCED, not assumed. The first field session
    /// caught the original sin in one screenshot: three decode spans
    /// overlapping and finishing together, because an actor does NOT hold
    /// isolation across an await — the moment transcribe() suspends, the
    /// next decode walks in. The reentrancy law, violated by its own
    /// preacher. Now a waiter queue serializes for real: while-loop re-check
    /// after every wake (the law again), FIFO wake-up, release on every
    /// exit path via defer.
    func decode(_ samples: [Float]) async throws -> String {
        let pipeline = try await loadedPipeline()
        while decodeBusy {
            await withCheckedContinuation { decodeWaiters.append($0) }
        }
        decodeBusy = true
        defer {
            decodeBusy = false
            if !decodeWaiters.isEmpty { decodeWaiters.removeFirst().resume() }
        }
        let span = diagnostics?.signposts.begin("whisper.decode")
        defer { if let span { diagnostics?.signposts.end(span) } }
        return try await decodeBody(pipeline, samples)
    }

    private func decodeBody(_ pipeline: WhisperKit, _ samples: [Float]) async throws -> String {
        do {
            // The hint travels as WhisperKit's own option. `nil` here is
            // "as before" — the engine's behaviour for every caller that
            // never asked for a language is unchanged.
            let options = language.map { DecodingOptions(language: $0) }
            let results = try await pipeline.transcribe(audioArray: samples,
                                                        decodeOptions: options)
            let joined = results.map(\.text).joined(separator: " ")
            // Whisper emits non-speech CONTROL tokens like [BLANK_AUDIO] or
            // [MUSIC]; they are markers, not words a person said — stripped
            // here so no consumer ever mistakes them for transcription.
            let stripped = joined.replacingOccurrences(
                of: #"\[[A-Za-z_ ]+\]"#, with: "", options: .regularExpression)
            return stripped
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        } catch {
            throw TranscriptionFailure.engineFailed(String(describing: error))
        }
    }

    /// ONE load at a time — the same guard `decode` already has, and for
    /// the same reason an actor does not hold isolation across an await.
    /// The 4h review named this method and `NeuralVoice`'s as sharing the
    /// unguarded shape; the neural voice was then measured loading TWICE
    /// on Ryad's phone (INSTRUMENTS §28). This one holds ~142 MB rather
    /// than gigabytes, so it was never going to kill an app — but a
    /// duplicate load is still two downloads, two decodes of the same
    /// weights, and a promise of idempotence that was not true.
    private func loadedPipeline() async throws -> WhisperKit {
        // Read the configuration HERE, on the actor, so the build closure
        // captures values rather than isolated state.
        let model = model
        let folder = localModelFolder
        do {
            return try await held.value {
                let config = WhisperKitConfig(model: model)
                // WHERE THINGS LAND IS OURS, NOT A DEFAULT (4u, AC-212).
                // WhisperKit resolves its tokenizer folder as
                // `tokenizerFolder ?? downloadBase`, and with neither set
                // the tokenizer's home depends on the vendor's default.
                // `base` happened to land where `modelInstalled()` looks;
                // `small` did not — a loaded pipeline and an "installed"
                // of false, so the bake-off skipped the model it had just
                // fetched. Naming the base makes the model AND the
                // tokenizer land in the two folders this type checks.
                config.downloadBase = URL.documentsDirectory.appending(path: "huggingface")
                // AND IT MAY NOT FETCH (5a). The bytes are this library's
                // now — `ensureModel` puts them there — so the vendor is
                // told to load and nothing else. A load that cannot find
                // the model throws `modelNotFound` instead of quietly
                // fetching 142 MB behind a person's back, which is
                // D-078's doctrine made structural rather than implied.
                config.download = false
            // Errors only. WhisperKit defaults to verbose info logging
            // ("Loading models...", "Decoding Temperature: ..."), gated once
            // at its init by verbose + logLevel. NOT verbose=false: that maps
            // the level to .none and swallows real errors with the noise.
                config.logLevel = .error
            // Offline-first — found by a field experiment in airplane mode:
            // WhisperKit pings huggingface.co to check the model revision
            // even when the model sits on disk. With modelFolder set it
            // loads locally and never touches the network — the on-device
            // promise applies to STARTUP, not only to transcription. (The
            // tokenizer needs no folder: its load is local-first from the
            // cache that modelInstalled() now verifies file by file.)
                if (try? FileManager.default.contentsOfDirectory(
                        atPath: folder.path))?.isEmpty == false {
                    config.modelFolder = folder.path
                }
                // The reentrancy re-check that used to live here is the
                // holder's job now, and it does it for every caller rather
                // than only for the one that won.
                return LoadedWhisper(kit: try await WhisperKit(config))
            }.kit
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.assetDownloadFailed(String(describing: error))
        }
    }
}

/// One utterance's worth of audio, accumulated, then decoded once.
///
/// `@unchecked Sendable` with the same written contract as the Apple run:
/// the session calls `feed`/`finishAudio`/`cancel` strictly serially from
/// its one loop, so the converter and the accumulator are only ever touched
/// by those serial calls. The decode task is the adapter-boundary exception
/// (like AppleRun's bridge): it runs in the background so `finishAudio`
/// returns immediately — a session loop that waited seconds for a decode
/// would block the very overlap D-024 exists for. Its only effect is
/// yielding into `updates`; a dead run's yields die at the session's ticket.
private final class WhisperRun: TranscriptionRun, @unchecked Sendable {
    let updates: AsyncStream<TranscriptionUpdate>

    private let engine: WhisperEngine
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let out: AsyncStream<TranscriptionUpdate>.Continuation
    private var accumulated: [Float] = []
    private var decodeTask: Task<Void, Never>?
    private var torndown = false

    init(engine: WhisperEngine, converter: AVAudioConverter,
         sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.engine = engine
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        var handle: AsyncStream<TranscriptionUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
    }

    func feed(_ chunk: MultiModalKit.AudioChunk) async {
        guard !torndown,
              let inBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount))
        else { return }
        inBuffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            inBuffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.frameCount)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(chunk.frameCount) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        // Same SDK quirk as the Apple adapter: the block is marked @Sendable
        // but runs synchronously inside convert() — the box writes that down.
        final class HandOff: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let hand = HandOff(inBuffer)
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if let buffer = hand.buffer {
                hand.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .noDataNow
            return nil
        }
        guard conversionError == nil, outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData else { return }
        accumulated.append(contentsOf: UnsafeBufferPointer(
            start: channel[0], count: Int(outBuffer.frameLength)))
    }

    func finishAudio() async {
        guard !torndown else { return }
        torndown = true
        let samples = accumulated
        accumulated = []
        let engine = engine
        let out = out
        decodeTask = Task {
            do {
                let text = try await engine.decode(samples)
                out.yield(.final(text))
            } catch let failure as TranscriptionFailure {
                out.yield(.failed(failure))
            } catch {
                out.yield(.failed(.engineFailed(String(describing: error))))
            }
            out.finish()
        }
    }

    func cancel() async {
        let hadDecode = torndown
        torndown = true
        accumulated = []
        decodeTask?.cancel()
        if !hadDecode {
            out.finish()   // never decoded: the stream just ends, no final
        }
        // A cancelled decode still finishes its stream from the task; its
        // late yield, if any, dies at the session's ticket.
    }
}
