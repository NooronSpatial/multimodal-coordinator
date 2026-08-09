import AVFAudio
import MultiModalKit
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

    private let engine = AppleSpeechEngine()
    private var microphone: MicrophoneSource?
    private var pipeline: Task<Void, Never>?

    // MARK: - the model asset (the app's job, never the library's)

    func checkModel() async {
        engineState = await engine.modelInstalled() ? .ready : .modelMissing
    }

    func downloadModel() async {
        engineState = .downloading
        do {
            try await engine.ensureModel()
            engineState = .ready
        } catch let failure as TranscriptionFailure {
            engineState = .failed(Self.describe(failure))
        } catch {
            engineState = .failed(String(describing: error))
        }
    }

    // MARK: - the pipeline

    func start() {
        guard engineState == .ready, !isListening else { return }
        utterances.removeAll()
        droppedFrames = 0

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
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
            vad: EnergyVAD(config: .init(threshold: 0.02,
                                         hangoverFrames: Int(rate * 0.3))),
            clock: ContinuousClock(),
            config: .init(sampleRate: rate, pollInterval: .milliseconds(10),
                          chunkFrames: chunk, preRollChunks: 2))
        let transcription = TranscriptionSession(
            engine: engine,
            config: .init(format: AudioStreamFormat(sampleRate: rate, channels: 1)))

        isListening = true
        pipeline = Task { [weak self] in
            // Listeners are taken BEFORE the pumps run: no event is missed.
            let audioForSession = await pump.listen()
            let audioForUI = await pump.listen()          // the multicast, used for real
            let transcripts = await transcription.listen()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump.run() }
                group.addTask { await transcription.run(events: audioForSession.events) }
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
