import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
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

    var engineState: EngineState = .checking

    /// The mouth. Changing it restarts the pipeline, like every other
    /// choice that is baked into a running turn loop.
    var mouth: MouthChoice = TranscribeModel.storedMouth {
        didSet {
            UserDefaults.standard.set(mouth.rawValue, forKey: Self.mouthKey)
            guard mouth != oldValue else { return }
            if isListening { restart() }
            // BOTH, and the mind is not a typo. Its availability message
            // used to depend on WHICH MOUTH was selected (the retracted
            // memory conflict), and this setter only refreshed the voice
            // — so a warning set under one combination survived into
            // another and sat there, orange, describing a state that no
            // longer existed. A derived value must be recomputed by
            // everything it derives from.
            refreshMind()
            Task { await checkVoice() }
        }
    }
    /// The neural voice's own model state — SEPARATE from `engineState`,
    /// which belongs to the transcriber. Two models, two downloads, two
    /// ways to be missing; one shared state would have made "not ready"
    /// ambiguous on a screen whose job is to remove ambiguity.
    var voiceState: EngineState = .checking
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
    let neuralHost = AudioEnginePlaybackHost()
    /// `.stepped`, not the library's `.fused` default — because `.fused`
    /// DOES NOT LOAD on this phone:
    ///
    ///   modelLoadingFailed("MultiCodeDecoder: failed to load
    ///   MultiCodeDecoder.mlmodelc (function 'fused') on macOS 15 / iOS 18
    ///   or newer. MLModelConfiguration's .functionName must be nil unless
    ///   the model type is ML Program.")
    ///
    /// D-047 made `.fused` the default on measured evidence — 29% faster,
    /// RTF 0.752 against 1.066, no quality difference two instruments
    /// could find. That ruling was right on the OS it was taken on. This
    /// is an APP choosing what works on the device in its hand (D-027),
    /// not a reversal of the ruling; the library default is untouched and
    /// the honest cost is the 29%.
    var neuralVoice = TranscribeModel.storedLevers.makeVoice()

    /// THE FOUR LEVERS, on the phone (AC-143).
    ///
    /// A `var`, where this was a `let`. The decoder and the vocoder are
    /// fixed at a voice's birth — deliberately, because that is how the
    /// cushion can be derived from them and cannot drift — so turning a
    /// lever means building a NEW voice and giving the old one back.
    /// `retire()` is what makes that leave exactly one pipeline resident
    /// instead of a pile (AC-145).
    var levers: VoiceLevers = TranscribeModel.storedLevers {
        didSet {
            guard !awaitedElsewhere, !revertingLevers, levers != oldValue
            else { return }
            // A PICKER cannot await, so this one spawns. The bench calls
            // `apply(_:)` instead and awaits the same work — see AC-147.
            Task { await settleLevers(from: oldValue) }
        }
    }

    var settling = false
    var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set while putting `levers` back, so the `didSet` above does not treat
    /// the revert as a new request and start the whole dance again.
    var revertingLevers = false
    /// Set while `apply(_:)` is driving, so the `didSet` does not ALSO spawn
    /// a task for work its caller is already awaiting. Without it a sweep
    /// runs every configuration twice, once watched and once not.
    var awaitedElsewhere = false

    /// Why the last lever change was refused, or nil. Kept separately from
    /// `voiceState` because the state goes back to `.ready` on the reverted
    /// voice, and a refusal that vanishes the moment it is recovered from is
    /// a refusal nobody can read.
    var leverRefusal: String?

    /// VOICE FORENSICS (AC-104), added because a field run produced four
    /// adjectives and no numbers: hot, late, worse, "drunk". Each of
    /// these turns one adjective into something that can be read off a
    /// screen and argued with.
    ///
    /// What one reply cost to decode. `steadyRealTimeFactor` at or above
    /// 1.0 means this phone cannot decode as fast as it plays — and with
    /// the lead derived to ZERO from a MAC measurement (D-047), that
    /// means the player runs dry from the first buffer.
    var voiceMargin: DecodeMargin?
    // The graph-rate line is GONE, not hidden. It was added to test a
    // theory — that a 24 kHz voice was being played as 16 kHz — and the
    // theory died: PlaybackHost passes an explicit format into connect,
    // so a mismatch would crash rather than slur (INSTRUMENTS §14). A
    // dead instrument left on screen is worse than none, because the
    // next person reads it as evidence.
    // Thermal is NOT duplicated here. The health loop already reports it
    // (D-027) and the toolbar already wears the badge; a second reading
    // of the same fact is how two numbers start disagreeing.

    // MARK: - the sweep (AC-146 … AC-151)

    var sweepRows: [BenchRow] = []
    var sweepRunning = false
    var sweepProgress = 0
    var sweepTotal = 0
    /// Why the sweep would not run, or nil. AC-146: it REFUSES rather than
    /// dying, and an instrument that crashes the app is not an instrument.
    var sweepRefusal: String?
    var sweepTask: Task<Void, Never>?

    /// The mind. Changing it restarts the pipeline, like the mouth.
    var mind: MindChoice = TranscribeModel.storedMind {
        didSet {
            UserDefaults.standard.set(mind.rawValue, forKey: Self.mindKey)
            guard mind != oldValue else { return }
            if isListening { restart() }
            refreshMind()
        }
    }
    /// Why the Apple mind cannot answer right now, or nil (AC-110). The
    /// three reasons are different sentences on purpose: a person whose
    /// device cannot run the model needs different words from one whose
    /// download is still running.
    var mindUnavailable: String?
    /// The shield probe's label-and-latch (the echo probe's law: one
    /// field is both, so a parked error cannot disable the instrument).
    var shieldStatus: String?
    var shieldReport: [String] = []
    /// THE SPEAKER SHIELD (4g, AC-120): replies render on the capture
    /// engine, where the canceller can see them.
    ///
    /// DEFAULT ON since D-069 (F-1 = A), and the reinstall is why. D-060
    /// F-4 kept the LIBRARY default off — a library claims every device —
    /// and this app's toggle inherited that `false`. Then Ryad deleted the
    /// app to re-download the voice, the reinstall wiped UserDefaults back
    /// to the default, and his next conversation self-barged exactly as
    /// the orange label predicted ("it will interrupt itself"). A default
    /// that breaks the first conversation after every reinstall is not a
    /// safe default; this app claims ONE device, and that device's
    /// evidence (§23's matrix, §29's field log, §37's conviction) says
    /// the shielded arrangement is the working one. The library default
    /// stays off — D-060 F-4 is untouched.
    var speakerShield = TranscribeModel.storedFlag(
        TranscribeModel.shieldKey, default: true) {
        didSet {
            UserDefaults.standard.set(speakerShield, forKey: Self.shieldKey)
            guard speakerShield != oldValue else { return }
            if isListening { restart() }
        }
    }
    /// ONE generator, held: `prewarm()` pays the measured ~1.5 s model
    /// warm-up (INSTRUMENTS §22) once, outside anyone's first turn
    /// (AC-115). The INSTRUCTIONS are the app's text, not the library's
    /// (D-057 F-3, mechanism-not-policy): this reply is spoken, never
    /// read — the probe's count-to-ten came back as a markdown list, and
    /// without this sentence a voice would read list numbering aloud.
    let appleMind = AppleReplyGenerator(
        instructions: "Your reply will be spoken aloud by a synthetic voice "
            + "and never shown as text. Answer in ONE short sentence. Do not "
            + "add extra facts, background or explanation unless the person "
            + "asks for them. Never use lists, bullet points, numbered items, "
            + "markdown, code, or headings.",
        spokenRefusal: "I can't help with that one.")

    /// THE SECOND MIND's weights (4h, D-062 F-1 = A). `repoID` means the
    /// app may FETCH them — Whisper's shape, ruled by F-4 = A — but only
    /// when a person taps Download. Asking whether it is installed never
    /// starts anything.
    let localModel = LocalMindModel(repoID: LocalMind.repoID)
    /// THE CONVERSATION LOG. Built because a field report — "sometimes it
    /// just replies my question" — cannot be chased without the real
    /// exchange, and because the one fact that separates the two likely
    /// causes is WHICH BRAIN answered, which no screenshot shows.
    var turns: [ConversationTurn] = []

    /// A margin that arrived BEFORE its row existed, waiting for record().
    /// The 4n review broke the first version's assumption two ways: a
    /// mid-reply decode failure reports its margin while the mind is still
    /// streaming (no row yet), and a mouth that drains before the mind's
    /// terminal races record() with no ordering guarantee. The first
    /// version searched BACKWARD for any voiceless row and stamped a
    /// barged turn — fabricating voice evidence on the exact rows the
    /// design promises stay empty.
    var pendingVoiceMargin: DecodeMargin?

    /// When Listen was tapped, so every turn can say how far into the
    /// session it happened.
    var sessionStart: ContinuousClock.Instant?

    /// Fraction complete while the weights come down, or nil.
    /// Fraction complete while the weights come down, or nil.
    var localDownloadProgress: Double?

    // MARK: - the pressure probe (4i, AC-132's field half)

    var probeLines: [String] = []

    /// SAMPLES THE DESCENT while something expensive loads.
    ///
    /// The steady footprint is not what kills: TTSKit reports "Loading 6
    /// CoreML models concurrently", and six simultaneous compiles need
    /// transient memory far above what the finished models hold. That
    /// peak is invisible from outside — the app simply stops.
    ///
    /// So this writes a reading every 250 ms, flushed, while the load
    /// runs. If jetsam takes the process, the LAST line is how close it
    /// got before dying, which is the number nothing else can give us.
    var samplerBusy = false
    /// How many lines the LAST sampled phase actually wrote. Zero after a
    /// phase means the load returned inside one sample interval — nothing
    /// was watched, and AC-170 says the trace must say so instead of
    /// blessing it. The first field run printed `survived: yes` around
    /// exactly that, and only a human comparing four identical numbers by
    /// eye caught it.
    var lastPhaseSamples = 0

    /// The kernel's own alarm, recorded into the same trace. AC-139
    /// showed both in-process numbers blind to a load that kills, because
    /// CoreML prepares models in system daemons — so this is the only
    /// instrument positioned to see it (INSTRUMENTS §30).
    var pressureMonitor: MemoryPressureMonitor?

    /// Fetches the weights. EXPLICIT — a person taps, nothing else.
    /// What the download is doing, in words, at every stage.
    ///
    /// STICKY on purpose, and it exists because of a field report:
    /// "downloading is not starting after i klick the button". The old
    /// version reported only through `localDownloadProgress`, so a
    /// failure BEFORE the first progress callback showed as a flicker and
    /// the button coming back — visually identical to the tap doing
    /// nothing. A silent failure and an ignored tap must never look the
    /// same. `refreshMind()` deliberately does not clear this.
    var localDownloadStatus: String?

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

    var isListening = false
    var isSpeaking = false
    var utterances: [Utterance] = []
    var droppedFrames = 0

    // MARK: - the conversation (milestone 4d)

    /// Speak the replies aloud. OFF puts the app back in its Phase 2
    /// shape — record-only session, no mouth — which is also the honest
    /// A/B for what the talking session costs.
    var talkEnabled = TranscribeModel.storedFlag(
        TranscribeModel.talkKey, default: true) {
        didSet {
            UserDefaults.standard.set(talkEnabled, forKey: Self.talkKey)
            if isListening { restart() }
        }
    }
    /// F-4, AMENDED BY MEASUREMENT (D-043). It was ruled speaker-default
    /// because that is the honest hard case; the device then measured the
    /// reply arriving at peak 1.0000 while the canceller reported ACTIVE,
    /// so the hard case is the BROKEN case and a speaker default would
    /// ship a demo that barges itself out of the box. The default is now
    /// the route that works; the speaker is one toggle away, for
    /// measurement, and the screen says why.
    var useSpeaker = TranscribeModel.storedFlag(
        TranscribeModel.speakerKey, default: false) {
        didSet {
            UserDefaults.standard.set(useSpeaker, forKey: Self.speakerKey)
            if isListening { restart() }
        }
    }
    var turnState: TurnState = .idle
    var reply = ""
    /// The whole thought the generator received (AC-91) — 4c made visible.
    var wholeThought = ""
    var feltPauseMilliseconds: Int?
    /// The platform took the audio away. Nothing resumes by itself
    /// (F-5 = B): a person decides when a microphone turns back on.
    var wasInterrupted = false
    /// BARGE DIAGNOSTICS (AC-92). `onsetsWhileSpeaking` counts what the
    /// PUMP saw; `bargeCount` counts what the COORDINATOR did about it.
    /// Both climbing = the barge works and the mouth is deaf to cancel.
    /// Only the first climbing = the coordinator never acted.
    /// Neither climbing = the microphone never heard the voice at all.
    /// Three different bugs, one glance.
    var bargeCount = 0
    var onsetsWhileSpeaking = 0
    var lastTurnEvent = "—"
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

    /// THE RAW MICROPHONE LEVEL, ungated and always moving while the
    /// pipeline runs. Everything else on this screen is downstream of
    /// the gate, so when the gate is wrong there is nothing to look at —
    /// and a gate can be wrong in two opposite ways that feel identical.
    /// Too HIGH: no utterance ever opens. Too LOW: one opens, never
    /// ends, and no reply is ever produced. Both are "I speak and
    /// nothing happens". This is the number that tells them apart, and
    /// it is what a person should set the gate ABOVE.
    var inputLevel: Float = 0
    /// The loudest thing heard since Listen was tapped. A moving level
    /// is hard to read while speaking; the peak stays put.
    var inputPeak: Float = 0
    /// The ENGINE's own answer about whether it is running, not ours.
    /// They disagree exactly when something has gone wrong behind our
    /// back — which on this phone looked like the microphone indicator
    /// appearing and vanishing with no error at all.
    var engineAlive = false
    var engineReconfigurations = 0
    /// What calibration is doing or found. Nil when it has never run.
    var calibrationStatus: String?
    var isCalibrating = false

    /// The echo probe's results (AC-96): what the microphone delivers in
    /// a quiet room, and what it delivers while the phone is speaking.
    var probeSilence: (peak: Float, rms: Float)?
    var probeWhileSpeaking: (peak: Float, rms: Float)?
    var probeStatus: String?
    /// A failed probe's reason. Kept apart from `probeStatus`, which is
    /// also the re-entrancy latch — merging them once bricked the button.
    var probeFailure: String?
    /// Did the platform actually GRANT voice processing for this probe?
    var probeVoiceProcessingActive = false
    var probeRoute = ""

    var liveUtterance: Int?
    var utteranceStartSeconds = 0.0
    var utterancePeak: Float = 0

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
    var bakeoffRows: [BakeoffMeasurement] = []
    var bakeoffStatus: String?
    /// The health loop, closed on screen (D-027 F4-A: the pipeline reports,
    /// THIS APP decides — and what it decides, for now, is to show you).
    var thermal: ThermalState = .nominal
    var settlingCount = 0

    let diagnostics: PipelineDiagnostics
    let appleEngine: AppleSpeechEngine
    let whisperEngine: WhisperEngine

    init() {
        let diagnostics = PipelineDiagnostics()
        self.diagnostics = diagnostics
        self.appleEngine = AppleSpeechEngine(diagnostics: diagnostics)
        self.whisperEngine = WhisperEngine(diagnostics: diagnostics)
    }
    var microphone: MicrophoneSource?
    var pipeline: Task<Void, Never>?
    var coordinator: TurnCoordinator<ContinuousClock>?
    var interruptionObserver: (any NSObjectProtocol)?
    /// The other observer, and it guards against a CRASH rather than a
    /// glitch — see `observeForegroundLoss()` (D-079).
    var foregroundObserver: (any NSObjectProtocol)?
    /// Its symmetric half — see `rewarmMind()`.
    var becameActiveObserver: (any NSObjectProtocol)?

}
