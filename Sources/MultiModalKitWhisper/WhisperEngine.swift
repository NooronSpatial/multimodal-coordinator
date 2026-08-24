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
public actor WhisperEngine: TranscriptionEngine {
    public nonisolated let capabilities = EngineCapabilities(
        emitsPartials: false,
        wantsWholeUtterance: true,
        requiredSampleRate: 16_000
    )

    private let model: String
    private nonisolated let diagnostics: PipelineDiagnostics?
    private var pipeline: WhisperKit?

    public init(model: String = "base", diagnostics: PipelineDiagnostics? = nil) {
        self.model = model
        self.diagnostics = diagnostics
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

    /// Downloads (Hugging Face, ~142 MB for `base`) and loads the pipeline.
    /// Idempotent; the download half is skipped when the model is on disk.
    public func ensureModel() async throws {
        _ = try await loadedPipeline()
    }

    public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun {
        if pipeline == nil {
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

    private var loadBusy = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
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
            let results = try await pipeline.transcribe(audioArray: samples)
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
        if let pipeline { return pipeline }
        while loadBusy {
            await withCheckedContinuation { loadWaiters.append($0) }
            if let pipeline { return pipeline }
        }
        loadBusy = true
        defer {
            loadBusy = false
            // ALL of them, not one. A woken waiter here returns the cached
            // pipeline immediately (the `if let pipeline` inside the loop
            // above), so it never passes the baton, and a third concurrent
            // caller waits forever. Found in `Retirable` by a three-caller
            // test that HUNG, and this is the same shape one module over.
            // `decode` below keeps the one-at-a-time form on purpose: its
            // waiters always do the work, so the hand-off is real.
            let waking = loadWaiters
            loadWaiters = []
            for waiter in waking { waiter.resume() }
        }
        do {
            let config = WhisperKitConfig(model: model)
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
            let folder = localModelFolder
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == false {
                config.modelFolder = folder.path
            }
            let fresh = try await WhisperKit(config)
            // The reentrancy law: the await released the actor.
            if let pipeline { return pipeline }
            pipeline = fresh
            return fresh
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
