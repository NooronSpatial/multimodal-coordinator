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
        /// The SECOND MIND (4h): weights on this device, no Apple
        /// Intelligence, no network once downloaded.
        case local = "Local"
        var id: String { rawValue }
    }

    /// THE LOCAL MIND'S MODEL — one, named, not chosen.
    ///
    /// 4h shipped a picker (F-1 = C) so the PHONE could answer what the
    /// Mac could not, and it did: 4B runs at 2288 MB peak with 291–315 ms
    /// to the first word. Ryad then ruled 4B outright and removed 0.6B —
    /// its replies were bad enough that keeping it as a "fallback" would
    /// have meant offering a worse product as a feature (D-064).
    ///
    /// The 0.6B measurements stay in INSTRUMENTS. They were true, they
    /// paid for the ruling, and deleting them would hide the evidence.
    enum LocalMind {
        static let repoID = "mlx-community/Qwen3-4B-4bit"
        static let sizeOnDisk = "about 2.2 GB"
        /// Measured on a Mac, and the caption says so — these are not a
        /// phone's numbers (INSTRUMENTS §25).
        static let macBehaviour = "249–374 ms first word · reads through disfluency"
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
        /// ON DISK, being made ready — NOT fetched.
        ///
        /// From a field report: "every time i start the app i see
        /// downloading the voice!" He was right to ask. The files were
        /// already there; `ensureModel()` was compiling six CoreML
        /// components, which takes tens of seconds every launch, and the
        /// screen called that "Downloading". The work was real; the word
        /// was false — and a screen whose job is removing ambiguity had
        /// been the thing creating it.
        case preparing
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
    private var neuralVoice = TranscribeModel.storedLevers.makeVoice()

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

    /// APPLY AND WAIT — the shape AC-147 needs (SPEC §104, H-3).
    ///
    /// `restart()` gives no signal that a new configuration is up: it defers
    /// teardown into a detached Task and sets `isListening` false while the
    /// microphone is still being released. A sweep driven by that has
    /// nothing to wait ON, and the only alternatives are a delay or a retry
    /// count — both of which AC-147 forbids, and both of which are how every
    /// timing bug in this project started.
    ///
    /// So the work is a function that RETURNS when it is done, and the
    /// picker's `didSet` becomes the odd one out: it cannot await, so it
    /// spawns a task that calls the same function. One code path, two
    /// callers, and only one of them has to guess about anything.
    /// - Parameters:
    ///   - restoring: the bench giving the person's settings BACK, not a
    ///     lever change. Two behaviours differ: the AC-144 recovery must not
    ///     run (there is nothing better to fall back to — `previous` is a
    ///     bench row, and reverting to it would leave the SWEEP's last
    ///     configuration as the person's), and nothing is persisted.
    ///   - persisting: whether this configuration becomes the person's
    ///     stored choice. False for every bench-driven change: a sweep used
    ///     to write all four keys on every row, so a sweep that died left
    ///     its own last row as the person's settings.
    func apply(_ wanted: VoiceLevers,
               restoring: Bool = false,
               persisting: Bool = true) async {
        guard wanted != levers else { return }
        let previous = levers
        awaitedElsewhere = true
        levers = wanted
        awaitedElsewhere = false
        await settleLevers(from: previous,
                           restoring: restoring,
                           persisting: persisting)
    }

    private func settleLevers(from previous: VoiceLevers,
                              restoring: Bool = false,
                              persisting: Bool = true) async {
        // SERIALIZED (the review). Two lever changes in quick succession —
        // a picker tapped twice, or a picker tapped during a sweep — each
        // spawned their own settleLevers, and two full 1.1 GB loads
        // overlapped. Whoever is second waits for the first to finish
        // rather than racing it.
        while settling {
            await withCheckedContinuation { settleWaiters.append($0) }
        }
        settling = true
        defer {
            settling = false
            // ALL of them, not one — the stranded-waiter lesson from the
            // same review, and the same reason: a woken waiter here can
            // return without doing any work.
            let waking = settleWaiters
            settleWaiters = []
            for waiter in waking { waiter.resume() }
        }

        // THE CONVERSATION STOPS FIRST (D-070 F-2 = C, the app half).
        //
        // This used to retire the old voice, load the new one for tens of
        // seconds, and only THEN restart. For that whole window the live
        // TurnCoordinator still held the retired voice in a `let` — and a
        // turn firing in it would build a second pipeline beside the one
        // loading. The library now refuses that (the voice is terminal),
        // but refusing mid-turn is a dead reply; not creating the window is
        // better than surviving it.
        //
        // The cost, named: changing a lever mid-conversation visibly stops
        // the conversation until the new voice is ready. That was always
        // what happened, minus the pretence that the old one still worked.
        let wasListening = isListening
        if wasListening { await stopAndWait() }

        let retiring = neuralVoice
        neuralVoice = levers.makeVoice()
        voiceState = .checking
        await retiring.retire()
        await checkVoice()
        await keepTheVoiceUsable(after: previous, recovering: !restoring)
        // PERSIST LAST, and only what a person chose. This used to be the
        // first line — persist-before-verify — so a configuration that
        // failed to load was still written to disk and came back at the
        // next launch, and every sweep row overwrote the person's settings
        // on its way past.
        if persisting, !restoring { Self.store(levers) }
        if wasListening { start() }
    }

    /// `stop()` with a signal, which `stop()` itself does not give: its
    /// teardown is deferred into a detached Task, and `isListening` goes
    /// false while the microphone is still being released (SPEC §104, H-3).
    /// `restart()` already knew this and waited on the dying pipeline —
    /// this is that wait, named and reusable.
    private func stopAndWait() async {
        let dying = pipeline
        stop()
        _ = await dying?.value
    }

    private var settling = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set while putting `levers` back, so the `didSet` above does not treat
    /// the revert as a new request and start the whole dance again.
    private var revertingLevers = false
    /// Set while `apply(_:)` is driving, so the `didSet` does not ALSO spawn
    /// a task for work its caller is already awaiting. Without it a sweep
    /// runs every configuration twice, once watched and once not.
    private var awaitedElsewhere = false

    /// AC-144 — A REFUSAL MUST NOT COST THE VOICE THAT WORKED.
    ///
    /// `.fused` is offered on this phone on purpose (D-066 F-2), and on iOS
    /// 18+ it does not load:
    ///
    ///     modelLoadingFailed("MultiCodeDecoder: failed to load
    ///     MultiCodeDecoder.mlmodelc (function 'fused') … .functionName
    ///     must be nil unless the model type is ML Program.")
    ///
    /// `checkVoice()` already puts that text on screen. What it cannot do is
    /// give back the voice that was working, because by then the old one has
    /// been retired — and retiring first is not negotiable: loading the new
    /// pipeline beside the old one is two resident pipelines, which is the
    /// kill this project has recorded three times.
    ///
    /// So the recovery is to go BACK. The failed levers stay visible so the
    /// person can see what they chose and why it was refused, the error text
    /// stays on screen, and the voice that speaks is the one that worked.
    private func keepTheVoiceUsable(after previous: VoiceLevers,
                                    recovering: Bool = true) async {
        // A RESTORE HAS NOWHERE BETTER TO GO. When the bench hands the
        // person's settings back, `previous` is the sweep's last row —
        // reverting to it would install the bench's configuration as the
        // person's, which is precisely what restoring exists to undo.
        guard recovering else { return }
        guard case .failed(let reason) = voiceState else {
            leverRefusal = nil
            return
        }
        guard previous != levers else { return }
        leverRefusal = "\(describe(levers)) was refused — \(reason)"
        neuralVoice = previous.makeVoice()
        revertingLevers = true
        levers = previous
        revertingLevers = false
        Self.store(previous)      // the configuration that WORKS is the one to keep
        await checkVoice()
    }

    /// Why the last lever change was refused, or nil. Kept separately from
    /// `voiceState` because the state goes back to `.ready` on the reverted
    /// voice, and a refusal that vanishes the moment it is recovered from is
    /// a refusal nobody can read.
    private(set) var leverRefusal: String?

    private func describe(_ levers: VoiceLevers) -> String {
        (levers.decoder == .fused ? "fused" : "stepped")
            + " + " + (levers.vocoder == .throughputOptimized
                       ? "throughput" : "latency")
    }

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
    private func currentMouth(shieldHost: (any PlaybackHost)?) -> any SpeechSynthesizing {
        switch mouth {
        // The BEST INSTALLED voice, not the system default. The default
        // is a compact voice, which is why the field's verdict on this
        // mouth was "like a robot" (AC-105). If the phone has no
        // enhanced or premium voice downloaded, this returns a compact
        // one and nothing changes — which is why the name is on screen.
        case .apple: AppleSpeechSynthesizer(
            voiceIdentifier: appleVoiceIdentifier
                ?? AppleSpeechSynthesizer.bestInstalledVoice()?.identifier,
            // BEHIND THE SHIELD (4g, AC-121): Apple's PCM renders on the
            // capture engine too — both mouths, one road, the canceller
            // sees them all.
            renderingOn: shieldHost)
        case .neural: neuralVoice
        }
    }

    // MARK: - the sweep (AC-146 … AC-151)

    private(set) var sweepRows: [BenchRow] = []
    private(set) var sweepRunning = false
    private(set) var sweepProgress = 0
    private(set) var sweepTotal = 0
    /// Why the sweep would not run, or nil. AC-146: it REFUSES rather than
    /// dying, and an instrument that crashes the app is not an instrument.
    private(set) var sweepRefusal: String?
    private var sweepTask: Task<Void, Never>?

    var sweepMarkdown: String { BenchTable.markdown(sweepRows) }

    func runSweep() {
        guard !sweepRunning else { return }
        let plan = BenchConfiguration.phone
        let runsEach = 3
        sweepRows = []
        sweepProgress = 0
        sweepTotal = plan.count * runsEach
        sweepRefusal = nil
        sweepRunning = true
        sweepTask = Task {
            defer { sweepRunning = false; sweepTask = nil }
            do {
                sweepRows = try await BenchSweep.run(
                    plan, runsEach: runsEach, on: PhoneBenchStage(model: self))
            } catch BenchSweep.Refusal.refused(let why) {
                sweepRefusal = why
            } catch {
                sweepRefusal = "\(error)"
            }
        }
    }

    /// Cancellation keeps the rows already measured — a sweep stopped
    /// halfway still measured what it measured — and the levers still come
    /// back to what the person chose (AC-151).
    func stopSweep() { sweepTask?.cancel() }

    func noteSweepMeasurement() { sweepProgress += 1 }

    /// The voice the bench measures — the same object the conversation
    /// speaks with, never a fresh one built for the occasion. A bench that
    /// measured its own private voice would be measuring a configuration
    /// nobody is using.
    var benchVoice: NeuralVoice { neuralVoice }

    /// AC-149. `bargeCount` and `onsetsWhileSpeaking` are NOT in `start()`'s
    /// reset list, so across a sweep they accumulate and every row reports
    /// the sum of the rows before it.
    func resetBenchCounters() {
        bargeCount = 0
        onsetsWhileSpeaking = 0
    }

    /// Free dirty memory, or nil when the device will not say. NOT zero —
    /// `os_proc_available_memory` returns an ambiguous 0 on the machines
    /// that have no limit (INSTRUMENTS §30), and a bench row printing
    /// "0 MB" would be reporting a measurement it never made.
    func freeMegabytesNow() -> Int? {
        switch MemoryHeadroomReader.read() {
        case .bytes(let b): Int(b / 1_048_576)
        case .exhausted: 0
        case .unavailable: nil
        }
    }

    /// What the voice that exists is set to — read from the VOICE, never
    /// from `levers` (AC-143). The two disagree whenever an apply has not
    /// landed yet, and that is exactly when a person is looking.
    var voiceInForce: String { neuralVoice.inForce }

    /// WHY TAPPING LISTEN WOULD DO NOTHING, or nil — and the ONE place that
    /// decides it.
    ///
    /// There used to be two lists, and they drifted. The button disabled on
    /// three conditions; `start()` refused on five. The two it did not know
    /// about were a shield probe holding the audio session, and a neural
    /// voice that is not ready — both reachable, both producing exactly the
    /// silent dead button AC-110 forbids. Worse after the tab split: the
    /// evidence for both now lives in OTHER tabs, so the person tapping
    /// Listen could not even see the reason.
    ///
    /// So `start()` asks this, and the button asks this, and there is
    /// nothing left to drift. It returns a SENTENCE because a disabled
    /// control that cannot say why is only half honest.
    var listenRefusal: String? {
        if engineState != .ready { return "the speech model is not ready yet" }
        if probeStatus != nil {
            return "an echo probe is measuring — it holds the audio session"
        }
        if shieldStatus != nil {
            return "the shield probe is measuring — it holds the audio session"
        }
        if let conflict = memoryConflict { return conflict }
        if talkEnabled, mouth == .neural, voiceState != .ready {
            return "the neural voice is not ready — install it in Settings"
        }
        // ANY mind that cannot answer, not just Apple's: the review found
        // the Local mind able to start a session in which every turn fails
        // at the door — a dead conversation that looks alive.
        if talkEnabled, mind != .echo, let why = mindUnavailable { return why }
        return nil
    }

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
    private(set) var mindUnavailable: String?
    /// The shield probe's label-and-latch (the echo probe's law: one
    /// field is both, so a parked error cannot disable the instrument).
    private(set) var shieldStatus: String?
    private(set) var shieldReport: [String] = []
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
    private let appleMind = AppleReplyGenerator(
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
    private let localModel = LocalMindModel(repoID: LocalMind.repoID)
    /// Instructions are the APP's text, not the library's (D-027). The
    /// same sentence the Apple mind gets, because the constraint is the
    /// medium — this reply is heard, never read — not the model.
    /// Computed, not stored: `@Observable` cannot hold a `lazy`, and this
    /// costs nothing — the generator is a struct wrapping the SHARED
    /// actor, so every copy talks to the same loaded weights.
    private var localMind: MLXReplyGenerator {
        MLXReplyGenerator(
            model: localModel,
            instructions: "Your reply will be spoken aloud by a synthetic voice "
                + "and never shown as text. Answer in ONE short sentence. Do "
                + "not add extra facts, background or explanation unless the "
                + "person asks for them. Never use lists, bullet points, "
                + "numbered items, markdown, code, or headings.",
            maxTokens: 160)
    }
    /// THE CONVERSATION LOG. Built because a field report — "sometimes it
    /// just replies my question" — cannot be chased without the real
    /// exchange, and because the one fact that separates the two likely
    /// causes is WHICH BRAIN answered, which no screenshot shows.
    private(set) var turns: [ConversationTurn] = []

    private func record(_ turn: ConversationTurn) {
        turns.append(ConversationTurn(
            id: turns.count + 1, mind: turn.mind, heard: turn.heard,
            reply: turn.reply, firstTokenMs: turn.firstTokenMs,
            totalMs: turn.totalMs, failure: turn.failure,
            // ONLY when the local mind answered. MLX's peak is
            // process-wide, so stamping it on an Apple or Echo turn
            // reported a number that turn had nothing to do with — an
            // instrument answering a question it was not asked.
            peakMemoryMB: (turn.mind.hasPrefix("Local") && MLXRuntime.isAvailable)
                ? MLXRuntime.peakMemoryBytes / 1_048_576 : nil,
            bargedIn: turn.bargedIn))
    }

    func clearLog() { turns.removeAll() }

    /// The log as markdown, so it leaves the phone as DATA rather than as
    /// a photograph of a screen.
    var conversationLog: String {
        var out = "# Conversation log — MultiModalKit demo\n\n"
        out += "picker says: mind=\(mind.rawValue) · ear=\(choice.rawValue) "
        out += "· mouth=\(mouth.rawValue) · speaker shield=\(speakerShield)\n"
        out += "local model: \(LocalMind.repoID) · installed: "
        out += "\(localModel.modelInstalled()) · MLX runnable here: "
        out += "\(MLXRuntime.isAvailable)\n"
        // AC-132: the number that decides whether the mind and the neural
        // voice can coexist. It is the PHONE's dirty-memory headroom, not
        // a Mac's footprint — the distinction 4i exists for.
        switch MemoryHeadroomReader.read() {
        case .bytes(let b):
            out += "memory headroom: \(b / 1_048_576) MB before this app's limit\n"
        case .exhausted:
            out += "memory headroom: NONE — at or over the limit\n"
        case .unavailable(let why):
            out += "memory headroom: unavailable (\(why))\n"
        }
        out += "voice loaded: \(voiceState == .ready && mouth == .neural)\n"
        if MLXRuntime.isAvailable {
            out += "MLX memory now: active "
            out += "\(MLXRuntime.activeMemoryBytes / 1_048_576) MB · peak "
            out += "\(MLXRuntime.peakMemoryBytes / 1_048_576) MB\n"
        }
        if let why = mindUnavailable { out += "mind unavailable: \(why)\n" }
        if let status = localDownloadStatus { out += "download: \(status)\n" }
        out += "weights expected at: \(localModel.weights.path)\n"
        out += "\nNOTE: the `mind:` line under each turn is the brain that\n"
        out += "ACTUALLY answered, taken from the generator the coordinator\n"
        out += "held — not from the picker above. If they disagree, that is\n"
        out += "the finding.\n\n"
        if !probeLines.isEmpty {
            out += "\n## pressure probe\n\n```\n"
            out += probeLines.joined(separator: "\n")
            out += "\n```\n\n"
        }
        if turns.isEmpty { out += "_(no turns recorded yet)_\n" }
        for turn in turns {
            out += "## turn \(turn.id)\n"
            out += "mind: **\(turn.mind)**\n\n"
            out += "heard: \(turn.heard.isEmpty ? "_(nothing)_" : turn.heard)\n\n"
            out += "reply: \(turn.reply.isEmpty ? "_(no words)_" : turn.reply)\n\n"
            let first = turn.firstTokenMs.map { "\($0) ms" } ?? "never"
            out += "first word \(first) · total \(turn.totalMs) ms"
            if let mb = turn.peakMemoryMB { out += " · MLX peak \(mb) MB" }
            if turn.bargedIn { out += " · BARGED IN (no terminal — expected on interrupt)" }
            if let failure = turn.failure { out += " · FAILED: \(failure)" }
            out += "\n\n"
        }
        return out
    }

    /// THE PAIR FITS — measured, and this used to say the opposite.
    ///
    /// It reported "the 4B mind and the neural voice do not fit together"
    /// and disabled Listen, on the strength of a MAC's phys_footprint
    /// (2239 + 1112 = 3351). Ryad's phone then loaded both with **1011 MB
    /// to spare**, because the neural voice costs **111 MB** on iOS, not
    /// 1112: CoreML MAPS its weights, and mapped pages are clean, so they
    /// are not charged against a dirty memory limit. MLX has no mmap, so
    /// its 2225 MB is charged in full (INSTRUMENTS §29).
    ///
    /// What replaced the refusal is an ORDER, because the steady
    /// footprint was never the problem — the LOAD is. TTSKit compiles six
    /// CoreML models concurrently, and that transient peak is what killed
    /// the app twice: at 1105 MB free and at 2976 MB free. It survived at
    /// 3347 MB. So the voice is loaded FIRST, from maximum headroom,
    /// before the mind takes its 2.2 GB. See `RootView`'s launch sequence,
    /// where that order is now load-bearing rather than incidental.
    var memoryConflict: String? { nil }

    /// Fraction complete while the weights come down, or nil.    /// Fraction complete while the weights come down, or nil.
    private(set) var localDownloadProgress: Double?

    // MARK: - the pressure probe (4i, AC-132's field half)

    /// Where the probe writes. IN DOCUMENTS, and flushed after EVERY
    /// line, because the thing being measured is an app being killed.
    ///
    /// The MLX phone spike already paid for this lesson: two crashes
    /// produced no output at all because the trail lived in a view that
    /// died with the process. An instrument whose evidence dies with the
    /// failure it is measuring is not an instrument.
    private nonisolated var probeLog: URL {
        URL.documentsDirectory.appending(path: "pressure-probe.txt")
    }

    private(set) var probeLines: [String] = []

    /// Reads back a PREVIOUS run — including one that ended in a kill.
    func loadPreviousProbe() {
        guard let text = try? String(contentsOf: probeLog, encoding: .utf8)
        else { return }
        probeLines = text.split(separator: "\n").map(String.init)
    }

    private func probeSay(_ line: String) {
        probeLines.append(line)
        // Capped, because a 250 ms sampler over a long load writes a lot,
        // and a file that grows without bound is its own bug. The OLDEST
        // lines go, never the newest — the last line before a death is
        // the whole point.
        if probeLines.count > 4_000 { probeLines.removeFirst(500) }
        // Append and flush NOW. Not at the end — there may not be an end.
        try? probeLines.joined(separator: "\n")
            .write(to: probeLog, atomically: true, encoding: .utf8)
    }

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
    private var samplerBusy = false

    /// The kernel's own alarm, recorded into the same trace. AC-139
    /// showed both in-process numbers blind to a load that kills, because
    /// CoreML prepares models in system daemons — so this is the only
    /// instrument positioned to see it (INSTRUMENTS §30).
    private var pressureMonitor: MemoryPressureMonitor?

    /// UNWIRED, deliberately, after it crashed the app on relaunch.
    ///
    /// Two defects I can see by reading, and one I cannot rule out
    /// without Ryad's crash log:
    ///
    /// 1. **A pressure storm.** The handler wrote a line, and `probeSay`
    ///    rewrites the WHOLE trace file. Under real pressure the source
    ///    fires repeatedly, so the instrument answered memory pressure by
    ///    doing file I/O in a loop — reacting to a fire by pouring fuel.
    /// 2. **A retain cycle.** The event handler captured `source`, which
    ///    holds the handler, so `deinit` could never run and the monitor
    ///    outlived its owner.
    ///
    /// Both are fixed in the type. It stays disconnected until a crash
    /// log says whether it was actually the cause, because re-enabling a
    /// suspect on a hunch is how a second afternoon gets lost (D-054).
    private func watchSystemPressure() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = MemoryPressureMonitor { [weak self] level in
            Task { @MainActor in
                self?.probeSay("  *** SYSTEM MEMORY PRESSURE: \(level) ***")
            }
        }
    }

    private func sampling<T>(_ label: String,
                             _ work: () async throws -> T) async rethrows -> T {
        // ONE AT A TIME. The first AC-139 trace interleaved two samplers —
        // "+55.5s" beside "+0.0s" — because tapping the probe while the
        // LAUNCH load was still running started a second one into the same
        // file. Two writers, one file, and a trace nobody can read. Same
        // class as the double model load, one layer up.
        guard !samplerBusy else {
            probeSay("  (\(label): a load is already being sampled — "
                + "not starting a second, and not touching that trace)")
            return try await work()
        }
        samplerBusy = true
        // NOT watching system pressure here any more — see the comment on
        // `watchSystemPressure`. It is wired to nothing until it is safe.
        defer { samplerBusy = false }
        let sampler = Task { [weak self] in
            for tick in 0..<2_400 {          // 10 minutes, capped
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.probeSay(String(format: "    %@ +%.1fs  %@",
                                         label, Double(tick) * 0.25,
                                         self.headroomNow()))
                }
            }
        }
        defer { sampler.cancel() }
        return try await work()
    }

    /// Both numbers, because they measure different things and only one
    /// of them moved.
    ///
    /// AC-139's first trace showed headroom drifting 2322 -> 2309 MB over
    /// sixty seconds of loading six CoreML models — thirteen megabytes —
    /// while the app had previously been KILLED doing exactly this.
    /// `limit_bytes_remaining` tracks the DIRTY limit, and CoreML's
    /// weights are mapped, so they are clean and invisible to it.
    /// `phys_footprint` counts them, which is why a Mac saw 1112 MB where
    /// the phone's headroom saw 111.
    ///
    /// An instrument that cannot see the thing that kills is the shape
    /// this project keeps hunting, so both are recorded and the reader is
    /// told which is which.
    private func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private func headroomNow() -> String {
        let free: String = switch MemoryHeadroomReader.read() {
        case .bytes(let b): "\(b / 1_048_576) MB free (dirty)"
        case .exhausted: "NONE — at or over the limit"
        case .unavailable(let why): "unavailable (\(why))"
        }
        return "\(free) · footprint \(footprintMB()) MB"
    }

    /// THE THREE MEASUREMENTS, in one tap, in order, each one written to
    /// disk before the next begins.
    ///
    /// It deliberately loads the pair the demo otherwise REFUSES
    /// (memoryConflict), because refusing is what makes the pair
    /// unmeasurable — and 4i exists to find out whether the refusal is
    /// even true on this device.
    func runPressureProbe() async {
        probeLines = []
        probeSay("# pressure probe — \(LocalMind.repoID)")

        // HONEST BASELINE. The first version called this "baseline" while
        // launch had ALREADY prewarmed the mind, so it measured the wrong
        // thing and said the right word. Say what is resident.
        let mindAlready = MLXRuntime.isAvailable
            && MLXRuntime.activeMemoryBytes > 100 * 1_048_576
        probeSay("mind already resident: \(mindAlready) "
            + "(MLX active \(MLXRuntime.activeMemoryBytes / 1_048_576) MB)")
        probeSay("start:               \(headroomNow())")

        // THE VOICE FIRST, and the order is the point. The previous run
        // loaded the risky thing last and died before learning the cheap
        // fact — what the neural voice actually costs ON THIS PHONE. My
        // 1112 MB is a Mac's figure, and CoreML often MAPS weights, which
        // count differently against a dirty limit than MLX's do.
        probeSay("voice installed on disk: \(await neuralVoice.modelInstalled())")
        probeSay("loading the neural voice FIRST… (if this is the last line,")
        probeSay("  it died here, and the voice alone is the problem)")
        do {
            try await sampling("voice") { try await neuralVoice.ensureModel() }
            probeSay("+ voice loaded:      \(headroomNow())")
        } catch {
            probeSay("  voice FAILED:      \(error)")
        }

        probeSay("loading the mind… (if this is the last line, the PAIR is")
        probeSay("  the problem, and we now know the voice's real cost)")
        do {
            _ = try await sampling("mind") { try await localModel.ensureModel() }
            probeSay("+ mind loaded:       \(headroomNow())")
            probeSay("  MLX active:        \(MLXRuntime.activeMemoryBytes / 1_048_576) MB")
        } catch {
            probeSay("  mind FAILED:       \(error)")
        }

        probeSay("BOTH RESIDENT:       \(headroomNow())")
        probeSay("survived: yes")
    }

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
    private(set) var localDownloadStatus: String?

    func downloadLocalMind() {
        guard localDownloadProgress == nil else {
            localDownloadStatus = "already downloading — ignoring the tap."
            return
        }
        localDownloadProgress = 0
        localDownloadStatus = "starting the local mind (\(LocalMind.sizeOnDisk))…"
        Task { [localModel] in
            do {
                self.localDownloadStatus = "asking Hugging Face for \(LocalMind.repoID)…"
                try await localModel.download { fraction in
                    Task { @MainActor in
                        self.localDownloadProgress = fraction
                        self.localDownloadStatus = String(
                            format: "downloading the local mind — %.0f%%",
                            fraction * 100)
                    }
                }
                self.localDownloadProgress = nil
                // Proof, not hope: the download returning is not the same
                // as the files being usable. And it must judge the model
                // it actually DOWNLOADED — `localModel` may have been
                // replaced by the picker meanwhile, and the review caught
                // the first version reporting a perfectly good download as
                // broken because it asked the wrong object.
                let installed = localModel.modelInstalled()
                self.localDownloadStatus = installed
                    ? "installed at \(localModel.weights.lastPathComponent)."
                    : "download finished but the files are NOT usable — "
                        + "expected them at \(localModel.weights.path)"
                self.refreshMind()
            } catch {
                self.localDownloadProgress = nil
                self.localDownloadStatus = "download FAILED: \(error)"
            }
        }
    }

    /// The generator the coordinator gets. BOTH minds keep 4c's honest
    /// witness — the 🧠 line shows what the ledger delivered across the
    /// seam, whichever brain answers (AC-91's proof duty, unchanged).
    private var currentGenerator: any ReplyGenerating {
        let witness: @Sendable (String) -> Void = { [weak self] thought in
            Task { @MainActor in self?.wholeThought = thought }
        }
        let sink: @Sendable (ConversationTurn) -> Void = { [weak self] turn in
            Task { @MainActor in self?.record(turn) }
        }
        switch mind {
        case .echo:
            return ThoughtWitness(wrapped: PhoneEchoReply(onThought: witness),
                                  mindLabel: "Echo (a stand-in that REPEATS your words)",
                                  onThought: { _ in }, onTurn: sink)
        case .apple:
            return ThoughtWitness(wrapped: appleMind, mindLabel: "Apple",
                                  onThought: witness, onTurn: sink)
        case .local:
            return ThoughtWitness(wrapped: localMind, mindLabel: "Local (MLX)",
                                  onThought: witness, onTurn: sink)
        }
    }

    /// Reads the availability enum FRESH — a download can complete
    /// between two turns, and caching "unavailable" would turn a
    /// temporary state into a permanent verdict. When the mind is ready,
    /// the warm-up is paid here, not inside the first felt pause.
    func refreshMind() {
        if mind == .local {
            // THE GUARD BELONGS HERE, not only on the Listen button.
            //
            // The review caught this and it was a blocker of my own
            // making: LOADING is what costs the memory, and both models
            // load at LAUNCH — checkVoice() prepares the voice, this
            // prewarms the mind — long before anyone can tap anything.
            // Guarding the button stopped nothing. Worse, once the mind
            // and mouth started persisting, the forbidden pair survived a
            // restart, so the app would be killed on every cold start
            // with the picker permanently out of reach: a crash loop the
            // person could not escape from inside the app.
            guard memoryConflict == nil else {
                mindUnavailable = memoryConflict
                return                      // load NOTHING
            }
            // The simulator answer is STRUCTURAL, not a missing file
            // (D-061): MLX wants a shared-storage Metal heap and the
            // simulator's driver refuses. Saying so beats a dead button.
            guard MLXRuntime.isAvailable else {
                mindUnavailable = String(describing: MLXUnavailable.platformCannotRunMLX)
                return
            }
            guard localModel.modelInstalled() else {
                mindUnavailable = "the local mind is not downloaded yet — "
                    + "tap Download (\(LocalMind.sizeOnDisk), once)."
                return
            }
            mindUnavailable = nil
            localMind.prewarm()   // the measured 1.7 s load, paid off-turn
            return
        }
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

    // EVERY PICKER PERSISTS (Ryad). The ear and the Apple voice already
    // did; the mind, the mouth, the shield and the two toggles did not,
    // so every launch quietly reset them and the person re-chose from a
    // screen that looked like it remembered. A control that forgets is a
    // control that lies about its own state.
    // The levers are stored as four primitives rather than one encoded
    // blob: a blob that fails to decode after a TTSKit rename would take
    // every setting with it, and these are the settings a person reaches
    // for when something is already wrong.
    private static let decoderKey = "dev.nooron.demo.levers.decoder"
    private static let vocoderKey = "dev.nooron.demo.levers.vocoder"
    private static let temperatureKey = "dev.nooron.demo.levers.temperature"
    private static let leadKey = "dev.nooron.demo.levers.leadMS"
    static var storedLevers: VoiceLevers {
        let defaults = UserDefaults.standard
        var levers = VoiceLevers.phoneDefault
        if defaults.string(forKey: decoderKey) == "fused" { levers.decoder = .fused }
        if defaults.string(forKey: vocoderKey) == "throughput" {
            levers.vocoder = .throughputOptimized
        }
        // `object(forKey:)` first: `float(forKey:)` cannot tell "absent"
        // from "zero", and zero is a REAL temperature with a distinctive
        // sound (INSTRUMENTS §32). Reading it as "unset" would silently
        // change what the person chose.
        if defaults.object(forKey: temperatureKey) != nil {
            levers.temperature = defaults.float(forKey: temperatureKey)
        }
        if defaults.object(forKey: leadKey) != nil {
            levers.lead = .milliseconds(defaults.integer(forKey: leadKey))
        }
        return levers
    }
    static func store(_ levers: VoiceLevers) {
        let defaults = UserDefaults.standard
        defaults.set(levers.decoder == .fused ? "fused" : "stepped", forKey: decoderKey)
        defaults.set(levers.vocoder == .throughputOptimized ? "throughput" : "latency",
                     forKey: vocoderKey)
        if let temperature = levers.temperature {
            defaults.set(temperature, forKey: temperatureKey)
        } else {
            defaults.removeObject(forKey: temperatureKey)
        }
        if let lead = levers.lead {
            defaults.set(Int(lead.components.seconds * 1000
                + lead.components.attoseconds / 1_000_000_000_000_000), forKey: leadKey)
        } else {
            defaults.removeObject(forKey: leadKey)
        }
    }

    private static let mindKey = "dev.nooron.demo.mind"
    private static var storedMind: MindChoice {
        UserDefaults.standard.string(forKey: mindKey)
            .flatMap(MindChoice.init(rawValue:)) ?? .echo
    }
    private static let mouthKey = "dev.nooron.demo.mouth"
    private static var storedMouth: MouthChoice {
        UserDefaults.standard.string(forKey: mouthKey)
            .flatMap(MouthChoice.init(rawValue:)) ?? .apple
    }
    private static let shieldKey = "dev.nooron.demo.speakerShield"
    private static let talkKey = "dev.nooron.demo.talkEnabled"
    private static let speakerKey = "dev.nooron.demo.useSpeaker"
    /// `object(forKey:)` and not `bool(forKey:)`: the latter answers
    /// `false` for "never set", which would silently flip a default that
    /// is deliberately `true`.
    private static func storedFlag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
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
        // The mouth's half of the same guard. Preparing the voice is a
        // 1.1 GB load, and it must not happen when the mind has already
        // claimed 2.2 GB (INSTRUMENTS §27).
        guard memoryConflict == nil else {
            voiceState = .failed(memoryConflict ?? "")
            return
        }
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
        //
        // PREPARING, not downloading: `modelInstalled()` just said the
        // files are here, so this call is a load. Saying otherwise is how
        // a person comes to believe their phone re-downloads 1.1 GB at
        // every launch.
        voiceState = .preparing
        do {
            // AC-139: SAMPLE THE LAUNCH LOAD. This is the load that killed
            // the app twice — six CoreML models compiling concurrently —
            // and it happens before anyone can tap a probe button. By the
            // time the gauge is reachable, everything is already resident
            // and there is nothing left to watch.
            // NOT SAMPLED AT LAUNCH ANY MORE. AC-139 put the sampler
            // here because the peak happens here — and then Ryad's app
            // began losing headroom on every open until it died. A
            // measurement instrument that stops an app from starting has
            // stopped being an instrument: it is now the fault. Sampling
            // survives on the explicit probe button, where a person
            // chooses to pay for it and can stop by not tapping it.
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
        guard listenRefusal == nil, !isListening
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
            // THE SHIELD (4g, AC-120). D-049 turned this off when the
            // hosted arrangement killed capture; the shield matrix then
            // measured WHY (a Mac fact plus an ordering bug plus session
            // contamination) and found the calm arrangement — chain
            // before vp, restart as the belt (INSTRUMENTS §23). Opt-in
            // by ruling (D-060 F-4): the person flips it, the library
            // never assumes it.
            hostsPlayback: talkEnabled && speakerShield)
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
                synthesizer: currentMouth(shieldHost: speakerShield ? microphone.playbackHost : nil),
                // THE REPLY GATE, at last switched on (F-2 = B, 500 ms).
                //
                // AC-81 built this in 4c and the demo never set it, so the
                // assistant committed about 300 ms after Ryad stopped making
                // noise — less than a person's thinking pause. A 38-turn
                // field session measured the cost: SIX turns opened on a
                // fragment ("Okay, and uh,") and were killed 76 ms later by
                // him finishing his own sentence, and twelve carried a
                // previous turn's words forward.
                //
                // The gate holds the reply, and `handleGateExpired` builds
                // the prompt when it EXPIRES — so a continued sentence joins
                // the SAME thought, and a new utterance during the gate stops
                // the turn firing at all.
                //
                // POLICY, in the app, on purpose (D-027): the library's
                // default stays `.zero`. This number costs felt pause 1:1 —
                // 542 ms measured becomes about 1040 ms — and that is a
                // trade only the person holding the phone can price.
                config: .init(replyGate: .milliseconds(500)),
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
        let captureHost = microphone.playbackHost
        pipeline = Task { [weak self] in
            if let self, mouth == .neural {
                // WHERE THE REPLY RENDERS (4g): behind the shield it
                // goes to the CAPTURE engine's host — the whole point,
                // the canceller can only remove what its own unit
                // renders (D-043). Unshielded, the 4e arrangement stands.
                await neuralVoice.render(on: speakerShield ? captureHost : neuralHost)
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
        // SYMMETRIC with the shield probe (the 4d mutual-exclusion lesson,
        // third instrument): both act on the process-wide session, so
        // neither may run under the other. The 4g review flagged the
        // missing half; confirmed by reading — the shield checked the
        // echo's latch, the echo never checked the shield's.
        guard !isListening, probeStatus == nil, shieldStatus == nil else { return }
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

    /// THE SHIELD MATRIX v2 (4g, AC-119 — fourth iteration of the harness).
    ///
    /// v1's phone run caught the engine LYING TWICE: `start()` returned,
    /// the report said STARTED — and `running NO` at read time. With
    /// voice processing plus an output chain the engine starts and then
    /// kills itself inside the window, the 4e "engine killing its own
    /// graph" class; the tell is a mixer stuck at 44100 Hz against the
    /// session's 48000. v1 also contaminated arrangements through the
    /// shared session (two identical taps, different beeps heard), so v2
    /// cycles the session between arrangements — isolation, one variable.
    ///
    /// The new candidate encodes the known cure as a MEASUREMENT: observe
    /// the configuration change and RESTART the engine — 4e's
    /// reconfiguration watch counts these but never restarts. Witnesses
    /// per arrangement: session rate, engine alive at 0.5 s AND at the
    /// end, configuration changes counted, restarts attempted, frames,
    /// peak, mixer rate.
    func runShieldProbe() async {
        guard !isListening, probeStatus == nil, shieldStatus == nil else { return }
        shieldReport = []
        shieldReport.append("route: \(useSpeaker ? "speaker" : "receiver") · matrix v2 · beeps: LOW=plain MID=restart HIGH=order-swap")

        struct Arrangement {
            let name: String
            let vpInput: Bool
            let outputChain: Bool
            let chainBeforeVP: Bool
            let restartOnChange: Bool
            let toneHz: Float
        }
        let arrangements: [Arrangement] = [
            .init(name: "1 shipping", vpInput: true, outputChain: false,
                  chainBeforeVP: false, restartOnChange: false, toneHz: 0),
            .init(name: "2 vp+chain plain (LOW)", vpInput: true, outputChain: true,
                  chainBeforeVP: false, restartOnChange: false, toneHz: 440),
            .init(name: "3 vp+chain RESTART (MID)", vpInput: true, outputChain: true,
                  chainBeforeVP: false, restartOnChange: true, toneHz: 660),
            .init(name: "4 chain-then-vp (HIGH)", vpInput: true, outputChain: true,
                  chainBeforeVP: true, restartOnChange: false, toneHz: 880),
        ]

        for arrangement in arrangements {
            shieldStatus = "arrangement \(arrangement.name)…"
            // ISOLATION: each arrangement gets a fresh session activation,
            // so one arrangement's route renegotiation cannot poison the
            // next — v1's two identical taps heard different beeps.
            let session = PhoneSession(talking: true, useSpeaker: useSpeaker)
            do { try session.activate() } catch {
                shieldReport.append("\(arrangement.name): session REFUSED — \(error.localizedDescription)")
                continue
            }
            shieldReport.append(await Self.probeArrangement(
                vpInput: arrangement.vpInput, outputChain: arrangement.outputChain,
                chainBeforeVP: arrangement.chainBeforeVP,
                restartOnChange: arrangement.restartOnChange,
                toneHz: arrangement.toneHz, name: arrangement.name))
            session.deactivate()
            try? await Task.sleep(for: .milliseconds(300))
        }
        shieldStatus = nil
    }

    /// Restarts a self-stopping engine from the configuration-change
    /// notification. `@unchecked Sendable` demo-tier box: the engine is
    /// touched only from the notification queue and the probe's own
    /// teardown, which orders after removal of the observer.
    private final class EngineRestarter: @unchecked Sendable {
        let engine: AVAudioEngine
        let counts = Mutex<(changes: Int, restarts: Int)>((0, 0))
        init(_ engine: AVAudioEngine) { self.engine = engine }
        func noteChangeAndMaybeRestart(_ restart: Bool) {
            counts.withLock { $0.changes += 1 }
            guard restart, !engine.isRunning else { return }
            if (try? engine.start()) != nil {
                counts.withLock { $0.restarts += 1 }
            }
        }
    }

    private nonisolated static func probeArrangement(
        vpInput: Bool, outputChain: Bool, chainBeforeVP: Bool,
        restartOnChange: Bool, toneHz: Float, name: String
    ) async -> String {
        let engine = AVAudioEngine()
        do {
            if chainBeforeVP {
                if outputChain { _ = engine.mainMixerNode }
                if vpInput { try engine.inputNode.setVoiceProcessingEnabled(true) }
            } else {
                if vpInput { try engine.inputNode.setVoiceProcessingEnabled(true) }
                if outputChain { _ = engine.mainMixerNode }
            }
        } catch {
            return "\(name): vp REFUSED — \(error.localizedDescription)"
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return "\(name): input format INVALID (\(Int(format.sampleRate)) Hz)"
        }
        let meter = Mutex<(frames: Int, peak: Float)>((0, 0))
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
            meter.withLock {
                $0.frames += Int(buffer.frameLength)
                $0.peak = max($0.peak, peak)
            }
        }

        let restarter = EngineRestarter(engine)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine,
            queue: nil
        ) { _ in
            restarter.noteChangeAndMaybeRestart(restartOnChange)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            return "\(name): start REFUSED — \(error.localizedDescription)"
        }

        var player: AVAudioPlayerNode?
        if outputChain {
            let mixerRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            if mixerRate > 0,
               let toneFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: mixerRate, channels: 1,
                                              interleaved: false),
               let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat,
                                             frameCapacity: AVAudioFrameCount(mixerRate * 2)) {
                buffer.frameLength = AVAudioFrameCount(mixerRate * 2)
                if let channel = buffer.floatChannelData {
                    for i in 0..<Int(buffer.frameLength) {
                        channel[0][i] = 0.4 * sinf(2 * .pi * toneHz * Float(i) / Float(mixerRate))
                    }
                }
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: toneFormat)
                p.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                if engine.isRunning { p.play() }
                player = p
            }
        }

        try? await Task.sleep(for: .milliseconds(500))
        let aliveEarly = engine.isRunning
        try? await Task.sleep(for: .milliseconds(2000))
        let (frames, peak) = meter.withLock { $0 }
        let aliveEnd = engine.isRunning
        let (changes, restarts) = restarter.counts.withLock { $0 }
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        let mixerRate = outputChain
            ? engine.mainMixerNode.outputFormat(forBus: 0).sampleRate : 0

        if let p = player {
            p.stop()
            if engine.attachedNodes.contains(p),
               !engine.outputConnectionPoints(for: p, outputBus: 0).isEmpty {
                engine.detach(p)
            }
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        var line = String(format: "%@: frames %d · peak %.4f · alive %@/%@ · cfg %d · restarts %d · session %.0f",
                          name, frames, peak,
                          aliveEarly ? "y" : "N", aliveEnd ? "y" : "N",
                          changes, restarts, sessionRate)
        if outputChain { line += String(format: " · mixer %.0f", mixerRate) }
        return line
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
