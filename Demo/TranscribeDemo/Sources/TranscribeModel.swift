import AVFAudio
import MultiModalKit
import MultiModalKitTesting
import MultiModalKitWhisper
import Observation

/// The demo's one view model: microphone → ring → pump → session → screen.
///
/// Everything below the UI is the library, unchanged. What the APP owns —
/// deliberately, per AC-22 — is permissions, the audio session, and the
/// model download. Demo-tier liberties (allowed, D-016): an unstructured
/// pipeline task held and cancelled by this object, and real clocks.
@MainActor
@Observable
final class TranscribeModel {
    enum EngineChoice: String, CaseIterable, Identifiable {
        case apple = "Apple"
        case whisper = "Whisper"
        var id: String { rawValue }
    }

    enum EngineState: Equatable {
        case checking
        case modelMissing
        case downloading
        case ready
        case failed(String)
    }

    struct Utterance: Identifiable, Equatable {
        let id: Int
        var text: String
        var isFinal: Bool
        var failure: String?
    }

    private(set) var engineState: EngineState = .checking
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var utterances: [Utterance] = []
    private(set) var droppedFrames = 0

    var choice: EngineChoice = .apple {
        didSet {
            guard choice != oldValue, !isListening else { return }
            engineState = .checking
            Task { await checkModel() }
        }
    }
    private(set) var bakeoffRows: [BakeoffMeasurement] = []
    private(set) var bakeoffStatus: String?
    /// The health loop, closed on screen (D-027 F4-A: the pipeline reports,
    /// THIS APP decides — and what it decides, for now, is to show you).
    private(set) var thermal: ThermalState = .nominal
    private(set) var settlingCount = 0

    private let diagnostics: PipelineDiagnostics
    private let appleEngine: AppleSpeechEngine
    private let whisperEngine: WhisperEngine

    init() {
        let diagnostics = PipelineDiagnostics()
        self.diagnostics = diagnostics
        self.appleEngine = AppleSpeechEngine(diagnostics: diagnostics)
        self.whisperEngine = WhisperEngine(diagnostics: diagnostics)
    }
    private var engine: any TranscriptionEngine {
        choice == .apple ? appleEngine : whisperEngine
    }
    private var microphone: MicrophoneSource?
    private var pipeline: Task<Void, Never>?

    // MARK: - the model asset (the app's job, never the library's)

    func checkModel() async {
        let installed = switch choice {
        case .apple: await appleEngine.modelInstalled()
        case .whisper: await whisperEngine.modelInstalled()
        }
        engineState = installed ? .ready : .modelMissing
    }

    func downloadModel() async {
        engineState = .downloading
        do {
            switch choice {
            case .apple: try await appleEngine.ensureModel()
            case .whisper: try await whisperEngine.ensureModel()
            }
            engineState = .ready
        } catch let failure as TranscriptionFailure {
            engineState = .failed(Self.describe(failure))
        } catch {
            engineState = .failed(String(describing: error))
        }
    }

    // MARK: - the bake-off (AC-43): the SAME committed fixture as the Mac

    func runBakeoff() async {
        guard !isListening, bakeoffStatus == nil else { return }
        bakeoffRows = []
        guard let wav = Bundle.main.url(forResource: "ryad-en", withExtension: "wav"),
              let refURL = Bundle.main.url(forResource: "bakeoff-reference", withExtension: "txt"),
              let reference = try? String(contentsOf: refURL, encoding: .utf8),
              let audio = try? BakeoffHarness.loadAudio(wav) else {
            bakeoffStatus = "fixtures missing from the bundle"
            return
        }

        let engines: [(String, any TranscriptionEngine, Bool)] = [
            ("Apple SpeechAnalyzer", appleEngine, await appleEngine.modelInstalled()),
            ("Whisper base", whisperEngine, await whisperEngine.modelInstalled()),
        ]
        for (name, engine, installed) in engines {
            guard installed else {
                bakeoffStatus = "\(name): model not installed — skipped"
                continue
            }
            bakeoffStatus = "\(name): warm-up (excluded)…"
            _ = try? await BakeoffHarness.measure(
                engine: engine, label: "warmup",
                samples: audio.samples, sampleRate: audio.sampleRate, reference: reference)
            bakeoffStatus = "\(name): measuring…"
            do {
                let row = try await BakeoffHarness.measure(
                    engine: engine, label: name,
                    samples: audio.samples, sampleRate: audio.sampleRate, reference: reference)
                bakeoffRows.append(row)
            } catch {
                bakeoffStatus = "\(name): failed — \(error)"
            }
        }
        bakeoffStatus = nil
    }

    /// The rows as a markdown table — copy straight into BAKEOFF.md.
    var bakeoffMarkdown: String {
        var lines = ["| Engine | WER | sub | ins | del | decode settle | device |",
                     "|---|---|---|---|---|---|---|"]
        for row in bakeoffRows {
            lines.append(String(
                format: "| %@ | **%.1f%%** | %d | %d | %d | %.2f s | iPhone |",
                row.engineName, row.score.wer * 100, row.score.substitutions,
                row.score.insertions, row.score.deletions, row.decodeSeconds))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - the pipeline

    func start() {
        guard engineState == .ready, !isListening else { return }
        utterances.removeAll()
        droppedFrames = 0

        do {
            let session = AVAudioSession.sharedInstance()
            // Default mode ON PURPOSE: .measurement would switch off the
            // system's input processing INCLUDING automatic gain — learned on
            // the first field run ("I must speak loud and be near the phone").
            try session.setCategory(.record)
            try session.setActive(true)
        } catch {
            engineState = .failed("Audio session: \(error.localizedDescription)")
            return
        }

        // ~1.4 s of audio at 48 kHz; power-of-two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 16)
        let microphone = MicrophoneSource()
        do {
            try microphone.start(into: producer)
        } catch {
            engineState = .failed("Microphone: \(error.localizedDescription)")
            return
        }
        self.microphone = microphone

        let rate = microphone.sampleRate
        let chunk = Int(rate * 0.02)                       // 20 ms per verdict
        let pump = AudioPump(
            consumer: consumer,
            // Field-tuned: 0.01 opens the gate for normal speaking volume at
            // arm's length (0.02 was a laptop-mic value and ate quiet words).
            vad: EnergyVAD(config: .init(threshold: 0.01,
                                         hangoverFrames: Int(rate * 0.3))),
            clock: ContinuousClock(),
            // 200 ms of pre-roll: a word's quiet onset must survive a VAD
            // that only wakes on its loud middle.
            config: .init(sampleRate: rate, pollInterval: .milliseconds(10),
                          chunkFrames: chunk, preRollChunks: 10),
            diagnostics: diagnostics)
        let transcription = TranscriptionSession(
            engine: engine,
            config: .init(format: AudioStreamFormat(sampleRate: rate, channels: 1)),
            diagnostics: diagnostics)

        isListening = true
        let diagnostics = diagnostics
        pipeline = Task { [weak self] in
            // Listeners are taken BEFORE the pumps run: no event is missed.
            let audioForSession = await pump.listen()
            let audioForUI = await pump.listen()          // the multicast, used for real
            let transcripts = await transcription.listen()
            let health = diagnostics.health()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump.run() }
                group.addTask { await transcription.run(events: audioForSession.events) }
                // The thermal watcher — cancelled with the group, never
                // stop()ped: diagnostics lives across Listen sessions.
                group.addTask { await diagnostics.run() }
                group.addTask { [weak self] in
                    for await event in health.events {
                        await self?.show(health: event)
                    }
                }
                group.addTask { [weak self] in
                    for await event in audioForUI.events {
                        await self?.show(audio: event)
                    }
                }
                group.addTask { [weak self] in
                    for await event in transcripts.events {
                        await self?.show(transcript: event)
                    }
                }
                // The group is the wall: stop() ends the streams, then this
                // scope drains and returns. Nothing outlives the pipeline.
                _ = await group.next()
                await pump.stop()
                await transcription.stop()
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        isSpeaking = false
        microphone?.stop()
        microphone = nil
        pipeline?.cancel()
        pipeline = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - events → screen

    private func show(health event: HealthEvent) {
        switch event {
        case .thermal(let state): thermal = state
        case .settlingDecodes(let count): settlingCount = count
        case .ringDropped, .listenerFellBehind: break   // drops already on screen
        }
    }

    private func show(audio event: AudioEvent) {
        switch event {
        case .speechStarted: isSpeaking = true
        case .speechEnded: isSpeaking = false
        case .dropped(let frames, _): droppedFrames += frames
        case .audioSegment: break
        }
    }

    private func show(transcript event: TranscriptEvent) {
        switch event {
        case .partial(let text, let utterance, _):
            upsert(utterance) { $0.text = text }
        case .final(let text, let utterance, _):
            upsert(utterance) { $0.text = text; $0.isFinal = true }
        case .failed(let failure, let utterance, _):
            upsert(utterance) { $0.failure = Self.describe(failure) }
        case .truncated(let utterance, _):
            upsert(utterance) { $0.text += " …" }
        }
    }

    private func upsert(_ id: Int, _ change: (inout Utterance) -> Void) {
        if let index = utterances.firstIndex(where: { $0.id == id }) {
            change(&utterances[index])
        } else {
            var fresh = Utterance(id: id, text: "", isFinal: false, failure: nil)
            change(&fresh)
            utterances.append(fresh)
        }
    }

    private static func describe(_ failure: TranscriptionFailure) -> String {
        switch failure {
        case .modelNotInstalled: "The speech model is not installed."
        case .assetDownloadFailed(let reason): "Model download failed: \(reason)"
        case .audioFormatRejected: "The engine refused the audio format."
        case .engineFailed(let reason): "Engine error: \(reason)"
        }
    }
}
