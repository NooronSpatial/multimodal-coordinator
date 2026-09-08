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

    public let configuration: Configuration

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Runs the spine until the calling task is cancelled (F-4 = A).
    ///
    /// `observe` runs as one more child of the group, with the session's
    /// listeners already open. When it, or any child, ends, the actors are stopped
    /// so every stream finishes, the scope drains, and the teardown runs
    /// in order on the way out.
    public func run(observing observe: @escaping @Sendable (Session) async -> Void) async {
        let config = configuration
        // A mind without a mouth, or the reverse, is not a mode — it is a
        // bug in the caller (F-3 = B: together, or neither).
        precondition((config.mind == nil) == (config.mouth == nil),
                     "a conversation needs a mind AND a mouth; listen-only needs neither")

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
                replyGenerator: mind, synthesizer: mouth, config: config.turns,
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
