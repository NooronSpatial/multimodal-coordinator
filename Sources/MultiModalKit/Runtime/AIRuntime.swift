/// THE FRONT DOOR (4t, Runtime Phase A; D-093).
///
/// One composed way to run the spine. It assembles the pump, the
/// transcription session and — when a mind and a mouth are given — the
/// turn coordinator; opens every listener BEFORE any loop starts; runs
/// the loops as children of one structured group; and unwinds them in
/// the order that took a milestone to learn.
///
/// ## What it owns, and what it deliberately does not
///
/// It owns **sequence**. The two applications that existed before it did
/// not duplicate decisions — every value that differed between them was
/// policy D-027 and AC-22 pushed out of the library on purpose. They
/// duplicated ORDER, and order is where the accidents lived: a listener
/// opened after its loop started loses the first utterance, intermittently;
/// a session released while an engine still renders fails with `IsBusy`
/// under a `try?`. So this type has **no policy of its own** (AC-204): its
/// `Configuration` *contains* the existing config types and adds no field
/// the app did not already own.
///
/// ## The name, and what it does NOT yet do (D-093, F-5)
///
/// `AIRuntime` is the destination's name, taken early by ruling. Today it
/// composes a voice conversation and nothing else: it **cannot see, cannot
/// call a tool, has no permission layer and no model router.** Read the
/// name as a direction, not a claim.
///
/// ## The three rules it turns from comments into mechanism
///
/// 1. Listeners before loops — the app's and the spine's own, all opened
///    before the first `addTask` (AC-202).
/// 2. One task group; "the group is the wall": the first child to end
///    stops the actors, which finishes every stream, and the scope drains.
/// 3. Teardown order (AC-203): the actors stop → `stopRendering` →
///    `releaseSource`. The app supplies the bodies of steps 2 and 3; the
///    runtime supplies the moment.
///
public struct AIRuntime<C: Clock>: Sendable where C.Duration == Duration {

    /// Everything the door needs, and nothing it decides (F-2 = A).
    ///
    /// The three config types are the app's own, passed through untouched.
    /// None of them has a default here on purpose: a default in this type
    /// would be a policy claim (D-027), and AC-204 forbids exactly that.
    public struct Configuration: Sendable {
        // — the organs (F-3 = B: mind and mouth together, or neither) —
        /// The ring's read side. The app created the ring, started its
        /// source into the producer (it owns permissions and the audio
        /// session — AC-22), and hands over this half.
        public var consumer: AudioRingConsumer
        public var vad: any VoiceActivityDetecting
        public var ear: any TranscriptionEngine
        public var mind: (any ReplyGenerating)?
        public var mouth: (any SpeechSynthesizing)?

        // — the existing configs, untouched (F-2 = A) —
        public var pump: AudioPump<C>.Config
        public var transcription: TranscriptionSession.Config
        public var turns: TurnCoordinator<C>.Config

        // — the rails —
        public var clock: C
        public var diagnostics: PipelineDiagnostics?
        public var thermalPolicy: (any ThermalPolicy)?
        public var latencyReporter: (any LatencyReporter)?

        // — the teardown's steps 2 and 3, bodies supplied by the app —
        /// Step 2: what to stop AFTER the pipeline has drained and BEFORE
        /// the source is released — a render engine, typically. Nodes go
        /// before the engine stops; the engine stops before the session
        /// is released. `nil` when nothing renders.
        public var stopRendering: (@Sendable () async -> Void)?
        /// Step 3: release the source the app started. Last, always —
        /// releasing a session while an engine still renders fails with
        /// `IsBusy`, and that failure was swallowed by a `try?` for a
        /// whole milestone (`TranscribeModel+Pipeline.swift:266`).
        public var releaseSource: @Sendable () async -> Void

        public init(
            consumer: AudioRingConsumer,
            vad: any VoiceActivityDetecting,
            ear: any TranscriptionEngine,
            mind: (any ReplyGenerating)? = nil,
            mouth: (any SpeechSynthesizing)? = nil,
            pump: AudioPump<C>.Config,
            transcription: TranscriptionSession.Config,
            turns: TurnCoordinator<C>.Config,
            clock: C,
            diagnostics: PipelineDiagnostics? = nil,
            thermalPolicy: (any ThermalPolicy)? = nil,
            latencyReporter: (any LatencyReporter)? = nil,
            stopRendering: (@Sendable () async -> Void)? = nil,
            releaseSource: @escaping @Sendable () async -> Void
        ) {
            self.consumer = consumer
            self.vad = vad
            self.ear = ear
            self.mind = mind
            self.mouth = mouth
            self.pump = pump
            self.transcription = transcription
            self.turns = turns
            self.clock = clock
            self.diagnostics = diagnostics
            self.thermalPolicy = thermalPolicy
            self.latencyReporter = latencyReporter
            self.stopRendering = stopRendering
            self.releaseSource = releaseSource
        }
    }

    /// What the app may observe, and the one thing it may steer.
    ///
    /// The listeners are opened by the runtime BEFORE any loop runs, which
    /// is the whole point of handing them over rather than letting the app
    /// open its own. The conversation is handed over because an app
    /// interrupts it (a phone call, a Control Centre swipe), resumes it,
    /// and clears its memory — that is the coordinator's public surface,
    /// and hiding it would force the app back to hand-wiring.
    public struct Session: Sendable {
        public let audio: Broadcast<AudioEvent>.Listener
        public let transcripts: Broadcast<TranscriptEvent>.Listener
        /// Present when a mind and a mouth were given.
        public let turns: Broadcast<TurnEvent>.Listener?
        /// Present when diagnostics were given.
        public let health: Broadcast<HealthEvent>.Listener?
        /// Present when a mind and a mouth were given. Steer it; never
        /// `stop()` it — the runtime does that, in order, on the way out.
        public let conversation: TurnCoordinator<C>?
    }

    /// The error `init` throws, spelled from the runtime so a caller
    /// writes `AIRuntime<ContinuousClock>.ConfigurationError` (AC-241).
    /// The type itself is not generic — see `AIRuntimeConfigurationError`.
    public typealias ConfigurationError = AIRuntimeConfigurationError

    public let configuration: Configuration

    /// Throws `ConfigurationError` for a mind without a mouth or the
    /// reverse, and for a `turns` number the coordinator could not
    /// honour — at construction, before any loop exists (AC-241).
    public init(_ configuration: Configuration) throws(ConfigurationError) {
        // A mind without a mouth, or the reverse, is not a mode — it is a
        // bug in the caller (F-3 = B: together, or neither). Until 4v this
        // was a `precondition` inside `run`; D-101 judged it reachable by
        // a caller's CONFIGURATION — an app assembling its organs from its
        // own settings — so it is now an error the caller can read, and it
        // is checked HERE so the mistake surfaces before a loop starts.
        switch (configuration.mind == nil, configuration.mouth == nil) {
        case (false, true): throw .mindWithoutMouth
        case (true, false): throw .mouthWithoutMind
        default: break
        }
        // The coordinator's numbers are the app's too (D-092), and until
        // the 4v review they trapped INSIDE `run()` — after the microphone
        // was capturing, which is the hazard AC-241 exists to remove. The
        // whole configuration is checked, a mind given or not: a wrong
        // number is wrong before the organ that reads it is switched on,
        // and "the door refuses an invalid configuration" is one rule to
        // explain, not two.
        do { try configuration.turns.validate() } catch { throw .turns(error) }
        self.configuration = configuration
    }

    /// Runs the spine until the calling task is cancelled (F-4 = A).
    ///
    /// `observe` runs as one more child of the group, with the session's
    /// listeners already open. When it, or any child, ends, the actors are stopped
    /// so every stream finishes, the scope drains, and the teardown runs
    /// in order on the way out.
    public func run(observing observe: @escaping @Sendable (Session) async -> Void) async {
        // The mind/mouth pairing was checked by `init` (AC-241): a
        // `Configuration` that reached this line has both organs or
        // neither, so the `if let mind, let mouth` below is exhaustive.
        // `config.turns` passed `validate()` there too, which is why the
        // coordinator is built through its checked body below and this
        // function stays non-throwing.
        let config = configuration

        // 1. THE ACTORS — built, and NOT yet running. Nothing publishes
        //    until step 3, which is what makes step 2 safe.
        let pump = AudioPump(consumer: config.consumer, vad: config.vad, clock: config.clock,
                             config: config.pump, diagnostics: config.diagnostics)
        let transcription = TranscriptionSession(
            engine: config.ear, config: config.transcription,
            diagnostics: config.diagnostics, thermalPolicy: config.thermalPolicy)
        let coordinator: TurnCoordinator<C>?
        if let mind = config.mind, let mouth = config.mouth {
            coordinator = TurnCoordinator(
                checked: config.turns, replyGenerator: mind, synthesizer: mouth,
                clock: config.clock,
                latencyReporter: config.latencyReporter ?? SilentLatency(),
                diagnostics: config.diagnostics)
        } else {
            coordinator = nil
        }

        // 2. EVERY LISTENER, BEFORE ANY LOOP (AC-202) — the spine's own
        //    and the app's. A listener opened after its loop has started
        //    misses whatever was published in between; for the pump that
        //    is the first utterance, and it is lost intermittently, which
        //    is the worst way to lose anything. Subscription order also
        //    decides the multicast's drop accounting, so the spine's own
        //    listeners come first, as both demos had them.
        let audioForSession = await pump.listen()
        let audioForTurns: Broadcast<AudioEvent>.Listener? =
            coordinator == nil ? nil : await pump.listen()
        let transcriptsForTurns: Broadcast<TranscriptEvent>.Listener? =
            coordinator == nil ? nil : await transcription.listen()
        let session = Session(
            audio: await pump.listen(),
            transcripts: await transcription.listen(),
            turns: await coordinator?.listen(),
            health: config.diagnostics?.health(),
            conversation: coordinator)

        // 3. ONE GROUP, AND THE GROUP IS THE WALL (D-014, the iOS demo's
        //    shape). Every loop is a child, so a cancel reaches all of
        //    them. The FIRST child to end — usually the observer, or a
        //    loop noticing cancellation — trips the stops; the stops
        //    finish every broadcast; every other child's `for await`
        //    ends; the scope drains. Nothing outlives the conversation.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.run() }
            group.addTask { await transcription.run(events: audioForSession.events) }
            if let coordinator, let audioForTurns, let transcriptsForTurns {
                group.addTask {
                    await coordinator.run(audio: audioForTurns.events,
                                          transcripts: transcriptsForTurns.events)
                }
            }
            // The thermal watcher is app-owned and lives across sessions:
            // run here, cancelled with the group, never stop()ped.
            if let diagnostics = config.diagnostics {
                group.addTask { await diagnostics.run() }
            }
            group.addTask { await observe(session) }

            _ = await group.next()
            await pump.stop()
            await transcription.stop()
            await coordinator?.stop()
        }

        // 4. THE TEARDOWN, IN ORDER, ON THE WAY OUT (AC-203). The actors
        //    are stopped and the scope has drained — that was step 1.
        //    Step 2 stops whatever renders, so its nodes leave a live
        //    engine. Step 3 releases the source last: a session released
        //    while an engine still renders fails with `IsBusy`, and that
        //    failure hid under a `try?` for a whole milestone.
        await config.stopRendering?()
        await config.releaseSource()
    }
}

/// Nobody asked for latency reports. Not an organ and not a lie: the
/// coordinator's clocked initializer requires a reporter, and "silence"
/// is the honest value of an absent one.
private struct SilentLatency: LatencyReporter {
    func turnLatency(_ duration: Duration, turn: Int) {}
    func cancelLatency(_ duration: Duration, turn: Int) {}
}

/// WHAT THE FRONT DOOR REFUSES, AS AN ERROR (4v, AC-241; D-101's R8 row).
///
/// A conversation needs a mind AND a mouth; listen-only needs neither
/// (F-3 = B). Until 4v that rule was a `precondition` — the right tool
/// for an invariant a caller cannot reach, the wrong one for a
/// configuration a caller assembles at runtime. Aura reads its organs
/// from its own settings; a wrong pair must come back as a value it can
/// switch over and show, not as a crash it reads in a log afterwards.
/// The coordinator's numbers travel through the same door (`.turns`):
/// the 4v review found them trapping inside `run()`, after capture.
///
/// Not nested in `AIRuntime` on purpose: the runtime is generic over its
/// clock and the error must not be — a `catch` should not have to name a
/// clock. `AIRuntime.ConfigurationError` is a typealias to this type so
/// the spec's spelling works too.
public enum AIRuntimeConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `mind` was given and `mouth` was `nil`.
    case mindWithoutMouth
    /// `mouth` was given and `mind` was `nil`.
    case mouthWithoutMind
    /// `turns` carries a number the coordinator cannot honour; the
    /// coordinator's own error says which (`Config.validate()`).
    case turns(TurnCoordinatorConfigurationError)

    public var description: String {
        switch self {
        case .mindWithoutMouth:
            return "a mind needs a mouth: pass a mouth with the mind, or neither (listen-only)"
        case .mouthWithoutMind:
            return "a mouth needs a mind: pass a mind with the mouth, or neither (listen-only)"
        case .turns(let error):
            return "the turns configuration was refused: \(error)"
        }
    }
}
