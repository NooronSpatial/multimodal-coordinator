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
        /// FORENSICS (the Mac's 🔎 line, brought to the phone). Without
        /// these the first field run could only be described, not
        /// measured — and the echo question is entirely a question about
        /// levels: what does the microphone hear when the phone speaks?
        var peakRMS: Float = 0
        var milliseconds: Int = 0
        /// True when this utterance began while the assistant was SPEAKING
        /// — the signature of the echo loop. A run full of these is the
        /// machine hearing itself.
        var whileSpeaking = false
    }

    private(set) var engineState: EngineState = .checking
    private(set) var isListening = false
    private(set) var isSpeaking = false
    private(set) var utterances: [Utterance] = []
    private(set) var droppedFrames = 0

    // MARK: - the conversation (milestone 4d)

    /// Speak the replies aloud. OFF puts the app back in its Phase 2
    /// shape — record-only session, no mouth — which is also the honest
    /// A/B for what the talking session costs.
    var talkEnabled = true {
        didSet { if isListening { restart() } }
    }
    /// F-4, AMENDED BY MEASUREMENT (D-043). It was ruled speaker-default
    /// because that is the honest hard case; the device then measured the
    /// reply arriving at peak 1.0000 while the canceller reported ACTIVE,
    /// so the hard case is the BROKEN case and a speaker default would
    /// ship a demo that barges itself out of the box. The default is now
    /// the route that works; the speaker is one toggle away, for
    /// measurement, and the screen says why.
    var useSpeaker = false {
        didSet { if isListening { restart() } }
    }
    private(set) var turnState: TurnState = .idle
    private(set) var reply = ""
    /// The whole thought the generator received (AC-91) — 4c made visible.
    private(set) var wholeThought = ""
    private(set) var feltPauseMilliseconds: Int?
    /// The platform took the audio away. Nothing resumes by itself
    /// (F-5 = B): a person decides when a microphone turns back on.
    private(set) var wasInterrupted = false
    /// BARGE DIAGNOSTICS (AC-92). `onsetsWhileSpeaking` counts what the
    /// PUMP saw; `bargeCount` counts what the COORDINATOR did about it.
    /// Both climbing = the barge works and the mouth is deaf to cancel.
    /// Only the first climbing = the coordinator never acted.
    /// Neither climbing = the microphone never heard the voice at all.
    /// Three different bugs, one glance.
    private(set) var bargeCount = 0
    private(set) var onsetsWhileSpeaking = 0
    private(set) var lastTurnEvent = "—"
    /// The live input level — what the microphone hears RIGHT NOW. With
    /// the assistant speaking and nobody else in the room, this IS the
    /// echo residual, and comparing it to the gate answers AC-96 without
    /// any theory (D-038's `--levels` probe, in a phone's shape).
    private(set) var inputLevel: Float = 0
    /// The gate this device is currently using — on screen, and
    /// adjustable, because a level means nothing without the number it is
    /// judged against, and because AC-97 says the phone earns its own.
    /// 0.020 — THIS DEVICE'S OWN NUMBER (AC-97), earned from the echo
    /// probe rather than inherited. 0.010 came from Phase 2, when the app
    /// only listened and nothing ever played; with a mouth in the loop
    /// the reply leaks 0.0044–0.0094 on the receiver, so one run cleared
    /// 0.010 by six per cent. At 0.020 the leak has 2–4x headroom below
    /// and speech (0.05–0.26) has 2.5x above.
    var vadThreshold: Float = 0.02 {
        didSet { if isListening { restart() } }
    }

    /// The echo probe's results (AC-96): what the microphone delivers in
    /// a quiet room, and what it delivers while the phone is speaking.
    private(set) var probeSilence: (peak: Float, rms: Float)?
    private(set) var probeWhileSpeaking: (peak: Float, rms: Float)?
    private(set) var probeStatus: String?
    /// Did the platform actually GRANT voice processing for this probe?
    private(set) var probeVoiceProcessingActive = false
    private(set) var probeRoute = ""

    private var liveUtterance: Int?
    private var utteranceStartSeconds = 0.0
    private var utterancePeak: Float = 0

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
    private var coordinator: TurnCoordinator<ContinuousClock>?
    private var interruptionObserver: (any NSObjectProtocol)?

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
        reply = ""
        wholeThought = ""
        feltPauseMilliseconds = nil
        wasInterrupted = false

        // ~1.4 s of audio at 48 kHz; power-of-two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 16)
        // The session is handed to the LIBRARY, which orders its steps
        // around capture (D-042 F-1 = B). The app never calls setActive
        // by hand any more — that ordering was guaranteed by nobody.
        let microphone = MicrophoneSource(
            // Voice processing only when there is something to cancel.
            // Its numbers were measured on a Mac whose microphone is an
            // iPhone over Continuity — none of them transfer, so AC-96
            // re-measures here or claims nothing.
            voiceProcessing: talkEnabled,
            session: PhoneSession(talking: talkEnabled, useSpeaker: useSpeaker))
        do {
            try microphone.start(into: producer)
        } catch {
            engineState = .failed("Microphone: \(error.localizedDescription)")
            return
        }
        self.microphone = microphone
        observeInterruptions()

        let rate = microphone.sampleRate
        let chunk = Int(rate * 0.02)                       // 20 ms per verdict
        let pump = AudioPump(
            consumer: consumer,
            // 0.01 was earned in Phase 2, when this app only LISTENED —
            // no speaker, so no echo to cross it. The first 4d field run
            // showed the assistant barging itself on the phone, which is
            // that number meeting a loudspeaker centimetres from the
            // microphone. It is adjustable on screen now, because AC-97
            // says this device earns its own numbers from a run rather
            // than inheriting the Mac's.
            vad: EnergyVAD(config: .init(threshold: vadThreshold,
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
            diagnostics: diagnostics,
            // THIS APP's ruling (D-027/D-028): on a hot phone, sacrifice the
            // late settling decodes, loudly — the row will say so in words.
            thermalPolicy: ConservativeThermalPolicy())

        // The conversation, if the app is talking. Same coordinator, same
        // ledger, same phraser, same mouth as the Mac — AC-92's whole
        // point is that none of them needed an iOS variant.
        let coordinator: TurnCoordinator<ContinuousClock>? = talkEnabled
            ? TurnCoordinator(
                replyGenerator: PhoneEchoReply(onThought: { [weak self] thought in
                    Task { @MainActor in self?.wholeThought = thought }
                }),
                synthesizer: AppleSpeechSynthesizer(),
                clock: ContinuousClock(),
                latencyReporter: PhoneLatency(model: self))
            : nil
        self.coordinator = coordinator

        isListening = true
        let diagnostics = diagnostics
        pipeline = Task { [weak self] in
            // Listeners are taken BEFORE the pumps run: no event is missed.
            let audioForSession = await pump.listen()
            let audioForUI = await pump.listen()          // the multicast, used for real
            let transcripts = await transcription.listen()
            let health = diagnostics.health()
            let audioForTurns = coordinator == nil ? nil : await pump.listen()
            let transcriptsForTurns = coordinator == nil ? nil : await transcription.listen()
            let turnEvents = coordinator == nil ? nil : await coordinator?.listen()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump.run() }
                group.addTask { await transcription.run(events: audioForSession.events) }
                if let coordinator, let audioForTurns, let transcriptsForTurns {
                    group.addTask {
                        await coordinator.run(audio: audioForTurns.events,
                                              transcripts: transcriptsForTurns.events)
                    }
                }
                if let turnEvents {
                    group.addTask { [weak self] in
                        for await event in turnEvents.events {
                            await self?.show(turn: event)
                        }
                    }
                }
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
                await coordinator?.stop()
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        isSpeaking = false
        turnState = .idle
        microphone?.stop()          // the library releases the session, in order
        microphone = nil
        pipeline?.cancel()
        pipeline = nil
        coordinator = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func restart() {
        stop()
        start()
    }

    // MARK: - the echo probe (AC-96) — the phone's own numbers

    /// THE INSTRUMENT the first field run lacked.
    ///
    /// The pump publishes only sound the VAD already ACCEPTED, so "no
    /// utterances" is ambiguous — cancelled echo and a deaf microphone
    /// look identical from its output. The Mac learned this during the
    /// D-038 spike and answered it with a probe that reads the ring
    /// directly; this is that probe, in a phone's shape, and it needs no
    /// speech model at all — so it runs even where an engine will not.
    ///
    /// What it does: start capture, measure the quiet room, then SPEAK
    /// while measuring again. The difference between those two numbers,
    /// against the gate, is the whole echo question.
    func runEchoProbe() async {
        guard !isListening, probeStatus == nil else { return }
        probeStatus = "measuring the quiet room…"
        probeSilence = nil
        probeWhileSpeaking = nil

        let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 16)
        let microphone = MicrophoneSource(
            voiceProcessing: true,
            session: PhoneSession(talking: true, useSpeaker: useSpeaker))
        do {
            try microphone.start(into: producer)
        } catch {
            probeStatus = "microphone: \(error.localizedDescription)"
            return
        }
        defer { microphone.stop() }
        // ASKED FOR is not GOT. Without this, a loud residual is
        // ambiguous: the canceller may have been refused by the platform,
        // or it may be running and simply never see the reply. Those need
        // opposite fixes, so the probe must not leave it to inference.
        probeVoiceProcessingActive = microphone.voiceProcessingActive
        probeRoute = useSpeaker ? "speaker" : "receiver"

        var scratch = [Float](repeating: 0, count: consumer.capacity)
        /// Reads whatever the microphone has delivered since the last read
        /// — the raw truth, gate or no gate. Safe because the pump is NOT
        /// running here, so the ring's sole-reader rule still holds.
        func measure(for seconds: Double) async -> (peak: Float, rms: Float) {
            var peak: Float = 0
            var sumOfSquares: Float = 0
            var total = 0
            let rounds = Int(seconds * 4)
            for _ in 0..<max(rounds, 1) {
                try? await Task.sleep(for: .milliseconds(250))
                scratch.withUnsafeMutableBufferPointer { buffer in
                    let result = consumer.read(into: buffer)
                    for i in 0..<result.framesRead {
                        let sample = buffer[i]
                        peak = max(peak, abs(sample))
                        sumOfSquares += sample * sample
                    }
                    total += result.framesRead
                }
            }
            return (peak, (sumOfSquares / Float(max(total, 1))).squareRoot())
        }

        probeSilence = await measure(for: 2)

        probeStatus = "speaking — stay quiet…"
        let speech = AVSpeechUtterance(string:
            "Measuring the echo. The microphone is listening to this sentence right now, "
            + "and the numbers on screen say whether the canceller removed it.")
        speech.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(speech)
        probeWhileSpeaking = await measure(for: 6)
        synthesizer.stopSpeaking(at: .immediate)

        probeStatus = nil
    }

    // MARK: - interruptions (AC-94, D-042 F-2 = A and F-5 = B)

    /// The app observes the platform notification and feeds the library a
    /// plain event. The core never learns what iOS is (F-2 = A), and the
    /// library's reaction — the turn dies like a failure, the words stay —
    /// is written once, in one place, instead of once per app.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in await self?.handle(interruption: type) }
        }
    }

    private func handle(interruption type: AVAudioSession.InterruptionType) async {
        switch type {
        case .began:
            // The platform already took the audio; the live turn must die
            // honestly rather than hang. Capture is torn down here too —
            // the graph is dead whether we admit it or not.
            await coordinator?.interrupt()
            wasInterrupted = true
            stop()
        case .ended:
            // NOTHING happens automatically (F-5 = B). The system's
            // `.shouldResume` hint is a hint TO THE APP; a person decides
            // when a microphone turns back on. The UI now offers it.
            break
        @unknown default:
            break
        }
    }

    /// The person tapped "resume". The thought is forgotten first — a call
    /// is a break in the conversation, and a pre-call fragment must not
    /// join a post-call sentence (F-5's second half).
    func resumeAfterInterruption() async {
        await coordinator?.resume()
        wasInterrupted = false
        reply = ""
        wholeThought = ""
        start()
    }

    // MARK: - events → screen

    private func show(health event: HealthEvent) {
        switch event {
        case .thermal(let state): thermal = state
        case .settlingDecodes(let count): settlingCount = count
        case .ringDropped, .listenerFellBehind: break   // drops already on screen
        case .settlingDecodeRefused: break   // the failed row says it in words
        }
    }

    private func show(audio event: AudioEvent) {
        switch event {
        case .speechStarted(let utterance, let at):
            isSpeaking = true
            liveUtterance = utterance
            utteranceStartSeconds = at.seconds
            utterancePeak = 0
            // The question the field run has to answer: was this the
            // person, or the phone hearing itself?
            let echo = turnState == .speaking
            if echo { onsetsWhileSpeaking += 1 }     // what the PUMP saw
            upsert(utterance) { $0.whileSpeaking = echo }
        case .speechEnded(let at):
            isSpeaking = false
            if let utterance = liveUtterance {
                let peak = utterancePeak
                let ms = Int((at.seconds - utteranceStartSeconds) * 1000)
                upsert(utterance) { $0.peakRMS = peak; $0.milliseconds = ms }
            }
            liveUtterance = nil
        case .dropped(let frames, _):
            droppedFrames += frames
        case .audioSegment(let chunk):
            var sumOfSquares: Float = 0
            for sample in chunk.samples { sumOfSquares += sample * sample }
            let rms = (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()
            utterancePeak = max(utterancePeak, rms)
            inputLevel = rms
        }
    }

    private func show(turn event: TurnEvent) {
        switch event {
        case .stateChanged(let state, _):
            turnState = state
            if state == .listening || state == .idle { reply = "" }
        case .replyToken(let token, _):
            reply += reply.isEmpty ? token : " " + token
        case .turnCompleted(let turn):
            lastTurnEvent = "completed \(turn)"
        case .turnBarged(let turn):
            // COUNTED AND SHOWN. The first conversation run failed with
            // "it kept talking when I talked", and the screen could not
            // say whether the coordinator had barged and the mouth
            // ignored it, or whether no barge ever happened — two
            // different bugs, indistinguishable from outside.
            bargeCount += 1
            lastTurnEvent = "BARGED \(turn)"
            reply = ""
        case .turnFailed(let failure, let turn):
            lastTurnEvent = "failed \(turn)"
            reply = ""
            if case .interrupted = failure { wasInterrupted = true }
        }
    }

    func show(feltPause duration: Duration) {
        feltPauseMilliseconds = Int(
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) * 1e-15)
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
        case .declinedUnderThermalPressure: "Decode skipped — device too hot."
        }
    }
}
