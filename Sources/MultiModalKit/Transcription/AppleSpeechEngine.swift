import AVFoundation
import Speech
import Synchronization

/// Apple's on-device engine (`SpeechAnalyzer` + `SpeechTranscriber`), behind
/// our seam (D-017). The session never sees a single Apple type — swap this
/// for the scripted engine or a Whisper module and no session line changes.
///
/// Three behaviors of the real API were learned in the spike and are handled
/// here, not discovered by users:
/// 1. **The model is an asset, not a given.** It must be downloaded via
///    `AssetInventory`; absence surfaces as `.modelNotInstalled` — an event,
///    never a crash (AC-22, AC-29).
/// 2. **`bestAvailableAudioFormat` is nil until assets exist** — so the run
///    can only be configured after availability is confirmed.
/// 3. **The results stream does not end by itself** when analysis finishes —
///    the bridge task must be torn down explicitly, on every path.
/// 4. **A segment final is PROGRESS, not the end.** On longer audio the
///    transcriber finalizes per segment; a run that stops at the first
///    `isFinal` loses everything after the first phrase. Found by the
///    bake-off, when 46.5 s of speech came back as 14 words (1 substitution,
///    78 deletions — the first sentence, perfect, then silence). The run's
///    ONE final is the JOIN of all segment finals, emitted at settle.
@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechEngine: TranscriptionEngine, ModelBacked, Sendable {
    public let capabilities = EngineCapabilities(emitsPartials: true)

    private let locale: Locale
    private let diagnostics: PipelineDiagnostics?

    public init(locale: Locale = Locale(identifier: "en_US"),
                diagnostics: PipelineDiagnostics? = nil) {
        self.locale = locale
        self.diagnostics = diagnostics
    }

    /// Is the model for this engine's locale on the device right now?
    public func modelInstalled() async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Fourth spike lesson — learned on a real iPhone, not in the spike:
    /// on-device speech assets are ALLOCATED per app. Without a reservation
    /// the modules come up empty ("Cannot use modules with unallocated
    /// locales"). Reserving is idempotent and quota-bound
    /// (`AssetInventory.maximumReservedLocales`), so it is done lazily, on
    /// both paths that need the model.
    private func reserveLocaleIfNeeded() async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else { return }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            throw TranscriptionFailure.engineFailed(
                "locale reservation failed: \(String(describing: error))")
        }
    }

    /// Downloads the model if needed (system-managed; may be slow, may fail —
    /// the spike watched it die with "final state: Network Error"). Safe to
    /// call again: an already-installed model returns immediately.
    public func ensureModel() async throws {
        try await ensureModel(progress: { _ in })
    }

    /// The same work, reporting the SYSTEM's fraction (5a, AC-291;
    /// D-114 F-6 = A).
    ///
    /// THE ONE ENGINE WHOSE BYTES ARE NOT THIS LIBRARY'S. Every other
    /// `ModelBacked` moves its own files through `ModelDownloader`; this
    /// one asks the operating system to install a speech asset, and the
    /// system decides where the bytes go, when they move and whether
    /// they are shared with other apps. So the fraction here is
    /// forwarded, not computed: `AssetInstallationRequest` reports a
    /// `Progress`, and this observes it — an EVENT, through key-value
    /// observation, never a poll — for as long as the install runs.
    ///
    /// The last word is still `1.0` exactly once, like every other
    /// engine: an already-installed model says it and asks the system
    /// for nothing.
    public func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await reserveLocaleIfNeeded()
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [])
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            progress(1.0)
            return
        case .unsupported:
            throw TranscriptionFailure.modelNotInstalled
        default:
            do {
                guard let request = try await AssetInventory
                    .assetInstallationRequest(supporting: [transcriber]) else {
                    progress(1.0)
                    return
                }
                // Held for the call's lifetime and released after it: an
                // observation that outlived its progress would report a
                // fraction nobody is waiting for.
                let watch = request.progress.observe(\.fractionCompleted, options: [.new]) { reported, _ in
                    let fraction = min(1, max(0, reported.fractionCompleted))
                    if fraction < 1 { progress(fraction) }
                }
                defer { watch.invalidate() }
                try await request.downloadAndInstall()
                progress(1.0)
            } catch let failure as TranscriptionFailure {
                throw failure
            } catch {
                throw TranscriptionFailure.assetDownloadFailed(String(describing: error))
            }
        }
    }

    /// The system owns these bytes, so this library cannot count them
    /// (AC-294, F-5 = A): `nil`, always, and no guess. A caller that
    /// wants a number for a system asset asks the system.
    public nonisolated func expectedDownloadBytes() -> Int64? { nil }

    /// Releases this engine's hold on the locale's assets (AC-295).
    ///
    /// AND SAYS PLAINLY WHAT IT CANNOT DO. The other four engines delete
    /// files they wrote; this one wrote none. Speech assets are the
    /// operating system's, installed per LOCALE and shared with every
    /// app on the device, so removing them here would be removing
    /// somebody else's model — the exact thing every other `deleteModel`
    /// in this library refuses to do. What this call owns is the
    /// RESERVATION (`AssetInventory.reserve`, taken lazily by
    /// `ensureModel`), and that is what it gives back; afterwards
    /// `modelInstalled()` reports whatever the system then says, which
    /// on most devices is still `true`.
    ///
    /// - Throws: `TranscriptionFailure.engineFailed` when the system
    ///   refuses to release the reservation.
    public func deleteModel() async throws {
        let reserved = await AssetInventory.reservedLocales
        guard reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        guard await AssetInventory.release(reservedLocale: locale) else {
            throw TranscriptionFailure.engineFailed(
                "the system would not release the reservation for \(locale.identifier(.bcp47))")
        }
    }

    public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun {
        try await reserveLocaleIfNeeded()
        // .fastResults alongside .volatileResults: faster partial cadence
        // for live use — the first field run showed the default cadence is
        // too chunky for a conversational screen.
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])

        // Spike lesson 2: a nil format IS "the model is not here".
        guard let engineFormat = await SpeechAnalyzer
            .bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionFailure.modelNotInstalled
        }
        guard let ourFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels), interleaved: false),
            let converter = AVAudioConverter(from: ourFormat, to: engineFormat) else {
            throw TranscriptionFailure.audioFormatRejected
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            throw TranscriptionFailure.engineFailed(String(describing: error))
        }

        return AppleRun(
            analyzer: analyzer, transcriber: transcriber, feed: feed,
            converter: converter, ourFormat: ourFormat, engineFormat: engineFormat,
            signposts: diagnostics?.signposts)
    }
}

/// One recognition. `@unchecked Sendable` with a written contract: the
/// session calls `feed`/`finishAudio`/`cancel` strictly serially from its one
/// loop — the mutable pieces (converter, teardown flag) are only ever touched
/// from those serial calls. The bridge task is the one concession to the real
/// API (spike lesson 3: its results stream must be read and must be killed);
/// it is created once, cancelled on BOTH exit paths, and its only effect is
/// yielding into `updates` — a dead run's yields die at the session's ticket.
@available(macOS 26.0, iOS 26.0, *)
private final class AppleRun: TranscriptionRun, @unchecked Sendable {
    let updates: AsyncStream<TranscriptionUpdate>

    private let analyzer: SpeechAnalyzer
    private let feedContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let ourFormat: AVAudioFormat
    private let engineFormat: AVAudioFormat
    private let bridge: Task<Void, Never>
    private let signposts: PipelineSignposter?
    private let updatesContinuation: AsyncStream<TranscriptionUpdate>.Continuation
    /// Segment finals collected so far — the bridge appends, settle joins.
    /// A reference box because Mutex itself is non-copyable.
    private final class SettledBox: Sendable { let store = Mutex<[String]>([]) }
    private let settled = SettledBox()
    private var torndown = false

    init(
        analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
        feed: AsyncStream<AnalyzerInput>.Continuation,
        converter: AVAudioConverter, ourFormat: AVAudioFormat, engineFormat: AVAudioFormat,
        signposts: PipelineSignposter? = nil
    ) {
        self.signposts = signposts
        self.analyzer = analyzer
        self.feedContinuation = feed
        self.converter = converter
        self.ourFormat = ourFormat
        self.engineFormat = engineFormat

        var handle: AsyncStream<TranscriptionUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.updatesContinuation = handle

        let out = handle!
        let settled = self.settled
        self.bridge = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // Lesson 4: every result — settled segment or volatile
                    // hypothesis — surfaces as a PARTIAL carrying the whole
                    // text so far. The ONE final is emitted at settle.
                    let joined = settled.store.withLock { box -> String in
                        if result.isFinal { box.append(text) }
                        let live = result.isFinal ? box : box + [text]
                        return live.joined(separator: " ")
                    }
                    out.yield(.partial(joined.trimmingCharacters(in: .whitespaces)))
                }
            } catch {
                out.yield(.failed(.engineFailed(String(describing: error))))
                out.finish()   // error is terminal; settle's yields become no-ops
            }
        }
    }

    func feed(_ chunk: AudioChunk) async {
        guard !torndown,
              let inBuffer = AVAudioPCMBuffer(
                pcmFormat: ourFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount))
        else { return }
        inBuffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            inBuffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.frameCount)
        }

        // Convert to whatever the engine wants (rate and layout may differ).
        let ratio = engineFormat.sampleRate / ourFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(chunk.frameCount) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: capacity)
        else { return }

        // The SDK marks the input block @Sendable, but convert() calls it
        // synchronously on this thread before returning — the box makes that
        // written-down fact visible to the compiler instead of silencing it
        // with @preconcurrency.
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
        guard conversionError == nil, outBuffer.frameLength > 0 else { return }
        feedContinuation.yield(AnalyzerInput(buffer: outBuffer))
    }

    func finishAudio() async {
        guard !torndown else { return }
        torndown = true
        feedContinuation.finish()
        // Settle: finalize flushes the remaining segments through the
        // bridge as finals. Then — reader first, so nothing can speak after
        // the final — the ONE final is the join of every settled segment.
        if let signposts {
            await signposts.measure("apple.settle") {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } else {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        bridge.cancel()
        let joined = settled.store.withLock { $0.joined(separator: " ") }
        updatesContinuation.yield(.final(joined.trimmingCharacters(in: .whitespaces)))
        updatesContinuation.finish()
    }

    func cancel() async {
        guard !torndown else { return }
        torndown = true
        feedContinuation.finish()
        bridge.cancel()            // spike lesson 3: the stream will not end itself
        updatesContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}
