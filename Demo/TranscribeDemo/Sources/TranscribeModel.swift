import AVFAudio
import MultiModalKit
import MultiModalKitTesting
import MultiModalKitTTS
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
    /// WHICH MOUTH SPEAKS (AC-105). The milestone's whole thesis was
    /// that a second implementation of `SpeechSynthesizing` needs no
    /// change anywhere else; this picker is where a listener gets to
    /// check that claim with their ears instead of reading it.
    enum MouthChoice: String, CaseIterable, Identifiable {
        case apple = "Apple"
        case neural = "Neural"
        var id: String { rawValue }
    }

    /// WHICH MIND ANSWERS (AC-117). The echo stays: it is the seam's
    /// scripted citizen, deterministic, offline, and the control group
    /// every real generator is compared against. The picker is the same
    /// claim the mouth picker makes one seam over — swapping the organ
    /// changes NOTHING else on the spine.
    enum MindChoice: String, CaseIterable, Identifiable {
        case echo = "Echo"
        case apple = "Apple"
        var id: String { rawValue }
    }

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

    /// The mouth. Changing it restarts the pipeline, like every other
    /// choice that is baked into a running turn loop.
    var mouth: MouthChoice = .apple {
        didSet {
            guard mouth != oldValue else { return }
            if isListening { restart() }
            Task { await checkVoice() }
        }
    }
    /// The neural voice's own model state — SEPARATE from `engineState`,
    /// which belongs to the transcriber. Two models, two downloads, two
    /// ways to be missing; one shared state would have made "not ready"
    /// ambiguous on a screen whose job is to remove ambiguity.
    private(set) var voiceState: EngineState = .checking
    /// Held, not rebuilt: the voice caches a loaded pipeline, and making
    /// a new one per turn would pay 1.1 GB of load again every time.
    /// The neural voice renders here, and THE DEMO OWNS IT so that it
    /// can be stopped (4e review, blocker 2).
    ///
    /// Left to itself the voice builds its own host on the first reply,
    /// starts that engine, and nothing ever stops it: `stopRendering()`
    /// had no production caller anywhere. The consequence is not
    /// abstract — an output unit running forever means
    /// `setActive(false)` fails with `IsBusy`, `PhoneSession` swallows
    /// it with `try?`, the `.playAndRecord` session is never released,
    /// and the person's music never comes back after Stop.
    private let neuralHost = AudioEnginePlaybackHost()
    private let neuralVoice = NeuralVoice()

    /// VOICE FORENSICS (AC-104), added because a field run produced four
    /// adjectives and no numbers: hot, late, worse, "drunk". Each of
    /// these turns one adjective into something that can be read off a
    /// screen and argued with.
    ///
    /// What one reply cost to decode. `steadyRealTimeFactor` at or above
    /// 1.0 means this phone cannot decode as fast as it plays — and with
    /// the lead derived to ZERO from a MAC measurement (D-047), that
    /// means the player runs dry from the first buffer.
    private(set) var voiceMargin: DecodeMargin?
    // The graph-rate line is GONE, not hidden. It was added to test a
    // theory — that a 24 kHz voice was being played as 16 kHz — and the
    // theory died: PlaybackHost passes an explicit format into connect,
    // so a mismatch would crash rather than slur (INSTRUMENTS §14). A
    // dead instrument left on screen is worse than none, because the
    // next person reads it as evidence.
    // Thermal is NOT duplicated here. The health loop already reports it
    // (D-027) and the toolbar already wears the badge; a second reading
    // of the same fact is how two numbers start disagreeing.

    /// The mouth the coordinator gets. Apple's is cheap to build fresh;
    /// the neural one is the held instance for the reason above.
    private var currentMouth: any SpeechSynthesizing {
        switch mouth {
        // The BEST INSTALLED voice, not the system default. The default
        // is a compact voice, which is why the field's verdict on this
        // mouth was "like a robot" (AC-105). If the phone has no
        // enhanced or premium voice downloaded, this returns a compact
        // one and nothing changes — which is why the name is on screen.
        case .apple: AppleSpeechSynthesizer(
            voiceIdentifier: appleVoiceIdentifier
                ?? AppleSpeechSynthesizer.bestInstalledVoice()?.identifier)
        case .neural: neuralVoice
        }
    }

    /// The mind. Changing it restarts the pipeline, like the mouth.
    var mind: MindChoice = .echo {
        didSet {
            guard mind != oldValue else { return }
            if isListening { restart() }
            refreshMind()
        }
    }
    /// Why the Apple mind cannot answer right now, or nil (AC-110). The
    /// three reasons are different sentences on purpose: a person whose
    /// device cannot run the model needs different words from one whose
    /// download is still running.
    private(set) var mindUnavailable: String?
    /// ONE generator, held: `prewarm()` pays the measured ~1.5 s model
    /// warm-up (INSTRUMENTS §22) once, outside anyone's first turn
    /// (AC-115). The INSTRUCTIONS are the app's text, not the library's
    /// (D-057 F-3, mechanism-not-policy): this reply is spoken, never
    /// read — the probe's count-to-ten came back as a markdown list, and
    /// without this sentence a voice would read list numbering aloud.
    private let appleMind = AppleReplyGenerator(
        instructions: "Your reply will be spoken aloud by a synthetic voice "
            + "and never shown as text. Answer in one to three short, plain "
            + "sentences. Never use lists, bullet points, numbered items, "
            + "markdown, code, or headings.",
        spokenRefusal: "I can't help with that one.")

    /// The generator the coordinator gets. BOTH minds keep 4c's honest
    /// witness — the 🧠 line shows what the ledger delivered across the
    /// seam, whichever brain answers (AC-91's proof duty, unchanged).
    private var currentGenerator: any ReplyGenerating {
        let witness: @Sendable (String) -> Void = { [weak self] thought in
            Task { @MainActor in self?.wholeThought = thought }
        }
        switch mind {
        case .echo: return PhoneEchoReply(onThought: witness)
        case .apple: return ThoughtWitness(wrapped: appleMind, onThought: witness)
        }
    }

    /// Reads the availability enum FRESH — a download can complete
    /// between two turns, and caching "unavailable" would turn a
    /// temporary state into a permanent verdict. When the mind is ready,
    /// the warm-up is paid here, not inside the first felt pause.
    func refreshMind() {
        guard mind == .apple else { mindUnavailable = nil; return }
        switch AppleReplyGenerator.availability {
        case nil:
            mindUnavailable = nil
            appleMind.prewarm()
        case .some(let reason):
            // THE LIBRARY OWNS THE WORDS (4f review): the same sentence a
            // mid-session failure prints is the one this caption shows, so
            // the two surfaces cannot drift apart.
            mindUnavailable = String(describing: reason)
        }
    }

    /// Every English voice this phone has, best quality first.
    /// Computed once: the list only changes when someone downloads a
    /// voice in Settings, which they cannot do without leaving the app.
    let availableAppleVoices = AppleSpeechSynthesizer.installedVoices(matching: "en")

    /// WHICH APPLE VOICE, chosen by the person rather than for them
    /// (Ryad's request). `nil` means "let the library pick the best
    /// installed one", which is what a fresh install starts from.
    ///
    /// Persisted like the gate, and for the same reason: a preference
    /// that has to be re-entered after every build is a preference that
    /// gets forgotten in the middle of a field run.
    var appleVoiceIdentifier: String? = TranscribeModel.storedVoice {
        didSet {
            UserDefaults.standard.set(appleVoiceIdentifier, forKey: Self.voiceKey)
            if isListening { restart() }
        }
    }
    private static let voiceKey = "dev.nooron.demo.appleVoice"
    private static var storedVoice: String? {
        UserDefaults.standard.string(forKey: voiceKey)
    }

    /// What will actually speak, named. A person who cannot see
    /// "compact" has no way to tell "the app ignored my download" from
    /// "this is as good as this phone gets".
    var appleVoiceDescription: String {
        if let appleVoiceIdentifier,
           let chosen = availableAppleVoices.first(where: { $0.id == appleVoiceIdentifier }) {
            return chosen.label
        }
        guard let voice = AppleSpeechSynthesizer.bestInstalledVoice() else {
            return "no voice found"
        }
        return AppleSpeechSynthesizer.describe(voice) + " (auto)"
    }
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
    /// The gate this device is currently using — on screen, and
    /// adjustable, because a level means nothing without the number it is
    /// judged against, and because AC-97 says the phone earns its own.
    /// 0.020 — THIS DEVICE'S OWN NUMBER (AC-97), earned from the echo
    /// probe rather than inherited. 0.010 came from Phase 2, when the app
    /// only listened and nothing ever played; with a mouth in the loop
    /// the reply leaks 0.0044–0.0094 on the receiver, so one run cleared
    /// 0.010 by six per cent. At 0.020 the leak has 2–4x headroom below
    /// and speech (0.05–0.26) has 2.5x above.
    /// **AND IT NOW SURVIVES A RELAUNCH** (Ryad's request, field
    /// session 2026-08-16). A gate is the number a field run is ABOUT,
    /// and re-typing it after every build is how a run gets done at the
    /// wrong value and believed anyway. Persisted so the device keeps
    /// what it earned.
    ///
    /// The default below is still 0.020 — the number D-042 earned on
    /// the receiver route. The field then measured a noise floor of
    /// 0.022–0.040 on this phone with the speaker on, so 0.020 silenced
    /// the app entirely (INSTRUMENTS §16). The stored value is what the
    /// device actually uses; the default is only what a fresh install
    /// starts from.
    var vadThreshold: Float = TranscribeModel.storedGate {
        didSet {
            UserDefaults.standard.set(vadThreshold, forKey: Self.gateKey)
            if isListening { restart() }
        }
    }

    private static let engineKey = "dev.nooron.demo.engine"
    private static var storedEngine: EngineChoice {
        UserDefaults.standard.string(forKey: engineKey)
            .flatMap(EngineChoice.init(rawValue:)) ?? .apple
    }

    private static let gateKey = "dev.nooron.demo.vadThreshold"
    private static var storedGate: Float {
        // `object(forKey:)` rather than `float(forKey:)`: the latter
        // returns 0 for "never set", and a gate of ZERO would open an
        // utterance on silence — a stored-default bug that looks exactly
        // like a broken VAD.
        guard let stored = UserDefaults.standard.object(forKey: gateKey) as? Float
        else { return 0.02 }
        return stored
    }

    /// THE RAW MICROPHONE LEVEL, ungated and always moving while the
    /// pipeline runs. Everything else on this screen is downstream of
    /// the gate, so when the gate is wrong there is nothing to look at —
    /// and a gate can be wrong in two opposite ways that feel identical.
    /// Too HIGH: no utterance ever opens. Too LOW: one opens, never
    /// ends, and no reply is ever produced. Both are "I speak and
    /// nothing happens". This is the number that tells them apart, and
    /// it is what a person should set the gate ABOVE.
    private(set) var inputLevel: Float = 0
    /// The loudest thing heard since Listen was tapped. A moving level
    /// is hard to read while speaking; the peak stays put.
    private(set) var inputPeak: Float = 0
    /// The ENGINE's own answer about whether it is running, not ours.
    /// They disagree exactly when something has gone wrong behind our
    /// back — which on this phone looked like the microphone indicator
    /// appearing and vanishing with no error at all.
    private(set) var engineAlive = false
    private(set) var engineReconfigurations = 0
    /// What calibration is doing or found. Nil when it has never run.
    private(set) var calibrationStatus: String?
    private(set) var isCalibrating = false

    /// MEASURES THE GATE INSTEAD OF GUESSING IT (AC-97).
    ///
    /// A whole field session went into two failures that feel identical
    /// — a gate above the voice (nothing ever opens) and a gate below
    /// the room (nothing ever ends) — and both were fixed by moving one
    /// slider to a value nobody could know without measuring. Worse, the
    /// right value CHANGED with the mouth: the same phone and the same
    /// voice measured a floor of 0.022–0.040 in one configuration and
    /// 0.002 in another, because the gain control settles elsewhere when
    /// the audio graph changes shape.
    ///
    /// So it is measured, here, on this device, in the configuration it
    /// is actually in. Three seconds of silence, four of speech, and the
    /// arithmetic lives in `GateCalibration` where it can be tested
    /// without a microphone.
    func calibrateGate() async {
        guard isListening, !isCalibrating else {
            calibrationStatus = "Tap Listen first."
            return
        }
        isCalibrating = true
        defer { isCalibrating = false }

        func loudest(over samples: Int) async -> Float {
            var peak: Float = 0
            for _ in 0..<samples {
                try? await Task.sleep(for: .milliseconds(100))
                peak = max(peak, microphone?.inputLevel ?? 0)
            }
            return peak
        }

        calibrationStatus = "Stay quiet…"
        let quiet = await loudest(over: 30)          // 3 s of room
        calibrationStatus = "Now speak normally…"
        let speech = await loudest(over: 40)         // 4 s of voice

        switch GateCalibration.suggestedGate(quiet: quiet, speech: speech) {
        case .gate(let suggested):
            vadThreshold = suggested                  // persists, and restarts
            calibrationStatus = String(
                format: "gate %.3f — room %.3f, voice %.3f", suggested, quiet, speech)
        case .tooClose(let quiet, let speech):
            // NOT papered over with an invented number. A gate placed
            // between two levels that are not apart is a coin toss
            // wearing three decimal places.
            calibrationStatus = String(
                format: "room %.3f and voice %.3f are too close — "
                      + "speak louder, or find a quieter place", quiet, speech)
        }
    }

    /// The echo probe's results (AC-96): what the microphone delivers in
    /// a quiet room, and what it delivers while the phone is speaking.
    private(set) var probeSilence: (peak: Float, rms: Float)?
    private(set) var probeWhileSpeaking: (peak: Float, rms: Float)?
    private(set) var probeStatus: String?
    /// A failed probe's reason. Kept apart from `probeStatus`, which is
    /// also the re-entrancy latch — merging them once bricked the button.
    private(set) var probeFailure: String?
    /// Did the platform actually GRANT voice processing for this probe?
    private(set) var probeVoiceProcessingActive = false
    private(set) var probeRoute = ""

    private var liveUtterance: Int?
    private var utteranceStartSeconds = 0.0
    private var utterancePeak: Float = 0

    /// Persisted, like the gate and the voice, and for the same reason:
    /// a choice that has to be re-made after every launch is a choice
    /// that gets forgotten in the middle of a field run — or, on a
    /// simulator, one that cannot be made at all, because the screen
    /// that offers it is replaced by the download prompt for whichever
    /// engine happened to be the default.
    var choice: EngineChoice = TranscribeModel.storedEngine {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.engineKey)
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

    /// Honest disk check for the VOICE. Asking never downloads.
    func checkVoice() async {
        guard mouth == .neural else { voiceState = .ready; return }
        guard await neuralVoice.modelInstalled() else {
            voiceState = .modelMissing
            return
        }
        // ON DISK IS NOT LOADED, and the difference is a frozen
        // conversation. `modelInstalled` only stats files; the pipeline
        // is built lazily by the first `openUtterance`, which the
        // coordinator awaits INLINE on its one serial loop. So the first
        // reply after launch would compile six CoreML components — tens
        // of seconds — while speech onsets, transcripts and barges piled
        // up unprocessed behind it, and the first turn's felt-pause
        // number would silently contain the model load.
        //
        // The 4e review found this one call above the identical fault
        // already fixed in `feed`. Warming here closes it completely
        // rather than shrinking it, because `start()` refuses to run
        // until this says ready.
        voiceState = .downloading
        do {
            try await neuralVoice.ensureModel()
            voiceState = .ready
        } catch {
            voiceState = .failed(String(describing: error))
        }
    }

    /// The voice's 1.1 GB, fetched once. Deliberately a separate button
    /// from the transcriber's download: they are different models, they
    /// fail for different reasons, and a single "Download" that could
    /// mean either would be a worse screen.
    func installVoice() async {
        voiceState = .downloading
        do {
            try await neuralVoice.ensureModel()
            // Trust the DISK, not the call returning. Phase 2's lesson,
            // and the one that caught a wrong model path in this very
            // milestone: a load can succeed against files the check
            // cannot find.
            voiceState = await neuralVoice.modelInstalled()
                ? .ready
                : .failed("loaded, but the disk check disagrees")
        } catch {
            voiceState = .failed(String(describing: error))
        }
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
        // The gate is SYMMETRIC (4d review). MicrophoneSource enforces
        // "activate once, release after the engine stops" per INSTANCE,
        // but PhoneSession acts on the process-wide AVAudioSession. The
        // probe already refused to run while listening; nothing stopped
        // listening from starting while a probe held the session, which
        // reconfigured it under a live tap and then released it under a
        // running graph — verbatim both failures the seam exists to
        // prevent.
        // The VOICE must be ready too, or the first reply fails
        // mid-turn with a missing model — a failure the screen would
        // report as a turn error when it is really a setup problem.
        // The MIND must be ready too, symmetrically with the voice: a
        // turn that dies on .modelNotReady is a setup problem the screen
        // would misreport as a turn error. Availability is read fresh —
        // the download may have finished since the last look.
        refreshMind()
        guard engineState == .ready, !isListening, probeStatus == nil,
              !(talkEnabled && mouth == .neural && voiceState != .ready),
              !(talkEnabled && mind == .apple && mindUnavailable != nil)
        else { return }
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
            session: PhoneSession(talking: talkEnabled, useSpeaker: useSpeaker),
            // FALSE, BY RULING (D-049). Rendering the reply on the
            // capture engine is reversed: voice processing and an output
            // chain cannot coexist on one engine (INSTRUMENTS §17), so
            // asking for one stopped capture from starting at all — the
            // phone's "state is always idle". The neural voice now uses
            // its own engine, its reply is not echo-cancelled on iOS
            // (D-043's cost, accepted again), and the capture-side host
            // waits for 4f behind the Mac harness that now exists.
            hostsPlayback: false)
        do {
            try microphone.start(into: producer)
        } catch {
            engineState = .failed("Microphone: \(error.localizedDescription)")
            return
        }
        self.microphone = microphone
        observeInterruptions()

        // THE POINT OF AC-104 (D-048, AC-108). The reply renders on the
        // CAPTURE engine — the one whose audio unit does the echo
        // cancelling — because D-043 measured that iOS voice processing
        // removes only what that unit itself renders. Every earlier
        // reply, Apple's included, was rendered somewhere the canceller
        // could not see, which is why the probe read 0.94-1.00 with the
        // canceller demonstrably working on everything else.
        //
        // AFTER `start`, never before: the host refuses to attach to a
        // microphone that is not capturing, and it is right to.

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
                replyGenerator: currentGenerator,
                synthesizer: currentMouth,
                clock: ContinuousClock(),
                latencyReporter: PhoneLatency(model: self),
                // D-059 = A: dead turns reach the health stream — the road
                // the mind's tripwire alarm rides.
                diagnostics: diagnostics)
            : nil
        self.coordinator = coordinator

        isListening = true
        inputPeak = 0
        let diagnostics = diagnostics
        // NO HOST IS INSTALLED (D-049). The voice makes its own engine,
        // which is the configuration that has worked since the hour it
        // was written. What stays is the margin reporting: the decode
        // numbers are how anyone will know whether this phone can run
        // this voice at all, and they do not depend on where it renders.
        pipeline = Task { [weak self] in
            if let self, mouth == .neural {
                await neuralVoice.render(on: neuralHost)
                await neuralVoice.reportMargins { margin in
                    // The graph's rate is refreshed HERE, with the
                    // margin, because it only becomes real when a reply
                    // has actually rendered: the host records it during
                    // attach rather than by poking a mixer that may not
                    // exist yet. Asking at start-up would have printed
                    // "not rendered yet" forever, which is the same
                    // family of mistake as the instrument that shipped
                    // dead an hour ago.
                    Task { @MainActor in self.voiceMargin = margin }
                }
            }
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
                // THE LEVEL METER. A poll, deliberately: the level is a
                // lock-free atomic written by the audio thread, and the
                // screen only needs it as fast as a person can read it.
                // Nothing downstream depends on this task, and it ends
                // with the group like everything else here.
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        let (level, alive, reconfigs) = await MainActor.run {
                            (self.microphone?.inputLevel ?? 0,
                             self.microphone?.engineIsRunning ?? false,
                             self.microphone?.configurationChanges ?? 0)
                        }
                        await MainActor.run {
                            self.inputLevel = level
                            self.inputPeak = max(self.inputPeak, level)
                            self.engineAlive = alive
                            self.engineReconfigurations = reconfigs
                        }
                        try? await Task.sleep(for: .milliseconds(100))
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
        // THE ORDER HERE IS THE FIX (4e review, blocker 2), and it has
        // three steps that cannot be swapped:
        //
        //   1. the pipeline dies      — so no reply is still speaking
        //   2. the render engine stops — its nodes go, safely, after 1
        //   3. the session is released — it cannot be, before 2
        //
        // Step 2 was missing entirely: nothing ever stopped the engine
        // the neural voice renders on, so `setActive(false)` failed with
        // `IsBusy`, `PhoneSession` swallowed it with `try?`, and the
        // .playAndRecord session stayed held for the life of the app —
        // the person's music never came back.
        //
        // Step 2 WAITS for step 1 rather than racing it: `stopRendering`
        // detaches nodes, and a reply still calling `play()` on a
        // detached node aborts the process. That is the same abort as
        // blocker 1, reached from the other side.
        let dying = pipeline
        pipeline = nil
        dying?.cancel()
        let host = neuralHost
        Task {
            await dying?.value               // the pipeline has drained
            host.stopRendering()             // now the nodes are nobody's
            await MainActor.run { microphone?.stop() }   // and the session goes
            await MainActor.run { microphone = nil }
        }
        coordinator = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    /// A toggle flipped mid-run rebuilds the pipeline. `stop()` only
    /// CANCELS the old task, so without awaiting it the previous run's
    /// buffered events could still drain into the fresh one and corrupt
    /// the forensics (4d review). Awaiting the cancelled task first makes
    /// the handover clean.
    private func restart() {
        let dying = pipeline
        stop()
        Task { [weak self] in
            _ = await dying?.value
            self?.start()
        }
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
            // NOT LEFT SET (4d review): probeStatus is both the label and
            // the re-entrancy latch, so parking an error string here
            // disabled the instrument for the life of the process — on
            // exactly the machines where a measurement matters most.
            probeFailure = "microphone: \(error.localizedDescription)"
            probeStatus = nil
            return
        }
        probeFailure = nil
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
        case .turnFailed: break   // the utterance's failure line says it in
                                  // words (D-059's road exists for listeners
                                  // OUTSIDE one conversation; this screen IS
                                  // the conversation)
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
        }
    }

    private func show(turn event: TurnEvent) {
        switch event {
        case .stateChanged(let state, _):
            turnState = state
            if state == .listening || state == .idle { reply = "" }
        case .replyToken(let token, _):
            // VERBATIM (4d review): tokens carry their own spacing —
            // that is the D-037 F-1 rule the phraser depends on — so
            // adding another space made the screen disagree with the
            // mouth on every word after the first.
            reply += token
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
