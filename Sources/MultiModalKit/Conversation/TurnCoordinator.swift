/// The library's namesake (SPEC §31, D-030, D-031): the conversation loop
/// above the transcription spine. Consumes the audio and transcript streams
/// the pipeline already broadcasts, drives the reply and synthesis seams,
/// and publishes `TurnEvent`s.
///
/// The law it exists to enforce (D-031): the ticket doctrine, promoted one
/// level. An utterance ticket protected one decode; the TURN ticket
/// protects a chain — generation feeding synthesis, both possibly
/// mid-flight when the user barges. The ticket is raised in the same actor
/// step as the retiring transition; every downstream event checks it before
/// acting. Cancellation is the optimization; the ticket is the guarantee.
///
/// The shape (one loop, one truth — the session's pattern): everything the
/// coordinator reacts to is merged into ONE stream and handled by ONE loop
/// on the actor. Stage readers are group children that only forward into
/// the merge; they never touch the actor.
public actor TurnCoordinator<C: Clock> where C.Duration == Duration {
    public struct Config: Sendable {
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int
        /// The reply gate (AC-81, D-037 F-3): how long the floor must stay
        /// yielded after a final before the generator opens. An onset during
        /// the gate kills the pending reply silently — "the utterance ended"
        /// is a weaker fact than "the user is done". Mechanism here, the
        /// NUMBER with the app (D-027). Zero = byte-for-byte 4a. A non-zero
        /// gate needs the clocked initializer.
        public var replyGate: Duration
        /// How many pieces of one thought the ledger keeps (AC-85,
        /// D-040 F-4). Bounded because F-2 keeps a FAILED turn's words:
        /// without a bound, an oversized prompt could fail, keep its
        /// words, and fail again — wedged forever. The number is the
        /// app's (D-027); this default is a starting point, not a law.
        public var maxContextPieces: Int

        public init(
            listenerBufferCapacity: Int = Broadcast<TurnEvent>.defaultBufferCapacity,
            replyGate: Duration = .zero,
            maxContextPieces: Int = 16
        ) {
            self.listenerBufferCapacity = listenerBufferCapacity
            self.replyGate = replyGate
            self.maxContextPieces = maxContextPieces
        }
    }

    /// Everything that can wake the loop, in one type.
    private enum Input: Sendable {
        case audio(AudioEvent)
        case transcript(TranscriptEvent)
        case reply(turn: Int, ReplyUpdate)
        case synthesis(turn: Int, SynthesisUpdate)
        /// The reply gate ran out (AC-81). Stamped with the turn AND the
        /// utterance it was armed for: both doors are checked on arrival,
        /// so a gate whose reply was killed expires into nothing.
        case gateExpired(turn: Int, utterance: Int)
        case audioEnded
        case transcriptsEnded
        case stopped
    }

    /// The live turn and its downstream chain. `current == nil` IS the
    /// retired ticket: every event stamped with a dead turn number stops at
    /// the guard that reads this.
    private struct LiveTurn {
        let turn: Int
        /// When this turn's final was accepted — the start of the pause the
        /// user feels. Captured only when a latency reporter is injected.
        var thinkingStart: C.Instant?
        /// The input-side ticket (SPEC §31): the utterance whose final may
        /// drive this turn. Mirrored from the same event stream the session
        /// numbers from. A settled final from an EARLIER utterance (D-024)
        /// is comfort text for apps — never a reply trigger.
        var utterance: Int
        /// A reply accepted but held behind the gate (AC-81). It is a
        /// FLAG, not the text: the words live in the ledger, so anything
        /// the speaker adds DURING the gate joins the thought that
        /// finally goes out. An onset while listening lowers it — the
        /// reply dies unspoken.
        var replyArmed = false
        var replyRun: (any ReplyRun)?
        var synthesisRun: (any SynthesisRun)?
        var tokensFinished = false
    }

    /// AC-61: the legal-transition table. The funnel checks every change
    /// against THIS — no state write happens anywhere else. (A computed
    /// property because generic types cannot hold static storage; the
    /// dictionary literal is trivially cheap next to a transition.)
    private static var legalTransitions: [TurnState: Set<TurnState>] {
        [
            .idle: [.listening],
            .listening: [.thinking, .idle],
            .thinking: [.speaking, .listening, .idle],
            .speaking: [.listening, .idle],
        ]
    }

    private let replyGenerator: any ReplyGenerating
    private let synthesizer: any SpeechSynthesizing
    private let config: Config
    private let broadcast: Broadcast<TurnEvent>
    /// The measurement pair (R2): both or neither. With no reporter the
    /// coordinator never reads a clock — clockless by default, like the
    /// session (D-011's spirit: time only where a consumer asked for it).
    private let clock: C?
    private let latencyReporter: (any LatencyReporter)?

    private var state: TurnState = .idle
    private var current: LiveTurn?
    private var nextTurn = 0
    /// The newest utterance identity SEEN here (D-034). Identities are
    /// assigned by the pump and carried in the events — this is a record
    /// of what arrived, never a parallel count. The review proved parallel
    /// counters over drop-tolerant streams desync forever; a number read
    /// from the event cannot.
    private var lastOnset = -1
    /// Reorder tolerance: the coordinator's two input streams cross two
    /// forwarders, so a final can reach the merge BEFORE its own
    /// `speechStarted` (tests hit this window constantly; production hits
    /// it rarely but legally). A terminal transcript from the FUTURE — its
    /// utterance not yet counted — waits here and is consumed the moment
    /// its `speechStarted` arrives. Everything else that fails the input
    /// door is genuinely stale or dead, and stays dropped.
    private var pendingTranscripts: [Int: TranscriptEvent] = [:]
    /// What the speaker said, kept whole (AC-85, D-040). Actor-scoped on
    /// purpose, NOT turn-scoped: a turn dies for reasons that have
    /// nothing to do with the words — an empty decode (the field's most
    /// common ending), a failure, a barge — and in every one of those
    /// the speaker never got an answer. It is emptied on `turnCompleted`
    /// and nowhere else (F-2 = A).
    private var ledger: TranscriptLedger
    /// Everything at or below this utterance belongs to a conversation
    /// that `resume()` ended. Set only there; it fences pre-interruption
    /// speech out of the fresh thought (the 4d review's finding).
    private var contextFloor = -1
    private var merge: AsyncStream<Input>.Continuation?
    private var isStopped = false
    /// The input streams' end, held on the ACTOR rather than in `run()`'s
    /// locals: a ticket retired from outside the loop has to be able to
    /// ask whether the loop still has work (see `wakeIfDrained`).
    private var audioEnded = false
    private var transcriptsEnded = false

    /// The measuring coordinator (R2): instants captured at the semantic
    /// boundaries, durations to the injected reporter. Deterministic under
    /// a ManualClock; a wall-clock demo reuses the identical code path.
    public init(
        replyGenerator: any ReplyGenerating,
        synthesizer: any SpeechSynthesizing,
        config: Config = Config(),
        clock: C,
        latencyReporter: any LatencyReporter
    ) {
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.clock = clock
        self.latencyReporter = latencyReporter
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
        self.ledger = TranscriptLedger(maxPieces: config.maxContextPieces)
    }

    /// The everyday coordinator: fully clockless — no reporter, no clock,
    /// not even a clock READ. Measurement is opt-in, never ambient.
    public init(
        replyGenerator: any ReplyGenerating,
        synthesizer: any SpeechSynthesizing,
        config: Config = Config()
    ) where C == ContinuousClock {
        precondition(config.replyGate == .zero,
                     "a reply gate needs time — use the clocked initializer")
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.clock = nil
        self.latencyReporter = nil
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
        self.ledger = TranscriptLedger(maxPieces: config.maxContextPieces)
    }

    /// The current state, for late listeners: ask for NOW, then listen —
    /// events replay nothing (D-030, AC-67).
    public var currentState: TurnState { state }

    /// The newest utterance identity seen here (D-034) — the input door's
    /// position, queryable the same "ask for now" way as the state.
    public var currentUtterance: Int { lastOnset }

    /// The thought as it stands: everything the speaker has said that has
    /// not yet been answered (AC-85). Same "ask for now, replay nothing"
    /// pattern as `currentState` (D-030) — an app can show what the
    /// assistant is about to answer, and a test can gate on the FACT that
    /// a final was recorded instead of hoping two tasks raced its way.
    public var currentContext: String { ledger.text }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<TurnEvent>.Listener {
        broadcast.listen()
    }

    /// Consumes both input streams until they end or `stop()` is called.
    /// Structured: the forwarders live and die inside this call's group.
    public func run(
        audio: AsyncStream<AudioEvent>,
        transcripts: AsyncStream<TranscriptEvent>
    ) async {
        guard !isStopped, merge == nil else { return }

        var handle: AsyncStream<Input>.Continuation!
        let inputs = AsyncStream<Input>(bufferingPolicy: .unbounded) { handle = $0 }
        let input = handle!
        merge = input

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in audio { input.yield(.audio(event)) }
                input.yield(.audioEnded)
            }
            group.addTask {
                for await event in transcripts { input.yield(.transcript(event)) }
                input.yield(.transcriptsEnded)
            }

            loop: for await item in inputs {
                if isStopped { break }
                switch item {
                case .audio(let event):
                    await handleAudio(event, forwardingInto: &group, via: input)
                case .transcript(let event):
                    await handleTranscript(event, forwardingInto: &group, via: input)
                case .reply(let turn, let update):
                    await handleReply(update, turn: turn, forwardingInto: &group, via: input)
                case .synthesis(let turn, let update):
                    await handleSynthesis(update, turn: turn)
                case .gateExpired(let turn, let utterance):
                    await handleGateExpired(turn: turn, utterance: utterance,
                                            forwardingInto: &group, via: input)
                case .audioEnded:
                    audioEnded = true
                case .transcriptsEnded:
                    transcriptsEnded = true
                case .stopped:
                    break loop
                }
                // Graceful end: no more triggers can arrive and no turn is
                // in flight — the loop's work is provably done.
                if isDrained { break }
            }
            group.cancelAll()   // frees any forwarder stuck on a defiant stream
        }

        merge = nil
        broadcast.finish()
    }

    /// The platform took the audio away (AC-94, D-042 F-3). The app calls
    /// this when it observes an interruption — a call, Siri, a route that
    /// vanished. The live turn dies exactly like a stage failure: ticket
    /// first, one event, back to idle. The LOOP survives; the next
    /// utterance starts a clean turn.
    ///
    public func interrupt() async {
        // The ticket dies FIRST, in this same actor step — before any
        // await, exactly as a barge does. Only then are the stages
        // cancelled, because cancellation is the optimisation and the
        // ticket is the guarantee.
        guard !isStopped, let dying = current else { return }
        failTurn(dying.turn, with: .interrupted)
        await dying.replyRun?.cancel()
        await dying.synthesisRun?.cancel()
        // Retiring from OUTSIDE the merge loop: if the inputs are already
        // finished, nothing will ever wake it again (the 4d review).
        wakeIfDrained()
    }

    /// The app has decided to listen again (AC-94, D-042 F-5 = B). Note
    /// what this is NOT: the platform's "interruption ended" hint. That
    /// hint goes to the app, and the app — or the person holding the
    /// phone — decides whether a microphone turns back on.
    ///
    /// Resuming forgets the thought. An interruption big enough to stop
    /// the pipeline is a break in the conversation, and without this a
    /// pre-call fragment would join a post-call sentence and be answered
    /// as one nonsense prompt (F-3 keeps the words; this is where they
    /// go). The ledger cannot expire by time — it has no clock, by
    /// design — but "resume" is a signal, and it costs nothing.
    ///
    public func resume() {
        ledger.clear()
        // Forgetting is not FENCING — the 4d review's catch. Clearing
        // empties what has arrived; it says nothing about pre-interruption
        // speech still in flight. Two doors have to shut:
        //   · anything already stashed in the reorder buffer belongs to
        //     the conversation that the call ended;
        //   · anything the recogniser flushes LATER for an utterance we
        //     had already seen must not enter the fresh thought either.
        // Without both, a pre-call fragment joins a post-call sentence —
        // exactly the nonsense F-5 was ruled to prevent.
        pendingTranscripts.removeAll()
        contextFloor = lastOnset
    }

    /// Ends the loop: the ticket dies in this same actor step, every
    /// listener's stream finishes, and the stage runs are cancelled AFTER
    /// the guarantee (AC-66, the D-014 doctrine).
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let dying = current
        current = nil                      // the ticket dies HERE — no gap
        merge?.yield(.stopped)
        broadcast.finish()
        await dying?.replyRun?.cancel()    // optimization, after the guarantee
        await dying?.synthesisRun?.cancel()
    }

    /// No more triggers can arrive and no turn is in flight.
    private var isDrained: Bool { audioEnded && transcriptsEnded && current == nil }

    /// The merge loop re-reads `isDrained` only when an item arrives, so a
    /// ticket retired from OUTSIDE the loop — which `interrupt()` is the
    /// first path to do — can leave it parked on streams that will never
    /// speak again. The 4d review caught it: `run()` never returned and
    /// every listener's stream stayed open. Whoever retires a ticket from
    /// outside must therefore knock.
    private func wakeIfDrained() {
        if isDrained { merge?.yield(.stopped) }
    }

    // MARK: - the funnel (AC-61: the ONLY writer of `state`)

    private func transition(to newState: TurnState, turn: Int) {
        assert(Self.legalTransitions[state]?.contains(newState) == true,
               "illegal transition \(state) → \(newState)")
        state = newState
        broadcast.publish(.stateChanged(newState, turn: turn))
    }

    // MARK: - audio events (the barge lives here, D-031)

    private func handleAudio(
        _ event: AudioEvent,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        guard case .speechStarted(let utterance, _) = event else { return }
        // segments, ends, drops: not turn business
        lastOnset = utterance

        switch state {
        case .idle:
            let turn = nextTurn
            nextTurn += 1
            current = LiveTurn(turn: turn, utterance: utterance)
            transition(to: .listening, turn: turn)

        case .listening:
            // The user paused and restarted before their final arrived: the
            // session barged its own utterance (D-024). Same turn, but the
            // input-side ticket moves to the NEWEST utterance — the earlier
            // one's final is stale the moment this event exists. A reply
            // held behind the gate dies HERE, silently (AC-81): the user
            // was not done, so nothing deserves an answer yet. (The armed
            // gate's expiry also fails its utterance door — this line is
            // the meaning, that guard is the proof.)
            current?.utterance = utterance
            current?.replyArmed = false

        case .thinking, .speaking:
            // THE BARGE. Ticket first, in this same actor step: the old
            // turn is dead before anything awaits.
            let bargeAccepted = clock?.now
            let dying = current
            let turn = nextTurn
            nextTurn += 1
            current = LiveTurn(turn: turn, utterance: utterance)
            if let dying {
                broadcast.publish(.turnBarged(turn: dying.turn))
            }
            transition(to: .listening, turn: turn)
            await dying?.replyRun?.cancel()      // optimization, after the
            await dying?.synthesisRun?.cancel()  // guarantee
            // Cancel latency (R2): barge accepted → both cancels
            // acknowledged. Belongs to the turn that died.
            if let reporter = latencyReporter, let clock, let bargeAccepted, let dying {
                reporter.cancelLatency(bargeAccepted.duration(to: clock.now), turn: dying.turn)
            }
        }

        // The utterance is born — if its terminal transcript arrived early
        // (cross-stream reorder), consume it NOW, in arrival order. STRICTLY
        // older pending entries can never see their onset again (identities
        // are monotonic at the source): pruned, self-healing after any drop.
        // The current key survives the prune — it is consumed on the next line.
        pendingTranscripts = pendingTranscripts.filter { $0.key >= utterance }
        if let early = pendingTranscripts.removeValue(forKey: utterance) {
            await handleTranscript(early, forwardingInto: &group, via: input)
        }
    }

    // MARK: - transcript events (the input-side ticket's door)

    private func handleTranscript(
        _ event: TranscriptEvent,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        switch event {
        case .final(let text, let utterance, _):
            // EVIDENCE FIRST (D-040). The words go into the ledger before
            // any door judges them, because the door decides what may
            // TRIGGER a reply, not what the speaker said. A refused final
            // is still speech; the ledger itself refuses only silence,
            // and identity makes a replayed final idempotent.
            //
            // …but only for an utterance whose ONSET WE HAVE SEEN. A final
            // can overtake its own `speechStarted` (separate forwarders),
            // and such a final is not part of the thought in progress — it
            // is a FUTURE utterance waiting below for its own turn. The
            // adversarial review proved what happens without this test:
            // the words joined the live prompt, the turn completed and
            // emptied the ledger, and the stashed final was then replayed
            // into a fresh one — answering the same sentence twice.
            if utterance <= lastOnset && utterance > contextFloor {
                ledger.record(text, utterance: utterance)
            }

            // THE INPUT DOOR: only the live turn, only while listening, and
            // only the CURRENT utterance's final. A stale settled final
            // (D-024) fails the third check and stays what it is — comfort
            // text for apps, never a reply trigger.
            guard let live = current, state == .listening, live.utterance == utterance
            else {
                if utterance > lastOnset {   // its onset has not arrived HERE
                    pendingTranscripts[utterance] = event   // reorder, not staleness
                }
                return                       // ≤ lastOnset: stale or dead — dropped
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // AC-64: nothing was said — no turn, no generator, back to idle.
                let turn = live.turn
                current = nil
                transition(to: .idle, turn: turn)
                return
            }

            let turn = live.turn
            current?.thinkingStart = clock?.now   // the user's wait begins
            if let clock, config.replyGate > .zero {
                // AC-81: hold the reply — the floor must stay yielded for
                // the whole gate. The sleeper is a group child (structured;
                // stop() cancels it with everything else) that only knocks:
                // the decision is made HERE, on the actor, when the knock
                // arrives — and both its stamps must still be true then.
                current?.replyArmed = true
                let deadline = clock.now.advanced(by: config.replyGate)
                let armedFor = live.utterance
                group.addTask {
                    try? await clock.sleep(until: deadline, tolerance: nil)
                    input.yield(.gateExpired(turn: turn, utterance: armedFor))
                }
                return
            }
            transition(to: .thinking, turn: turn)
            // The WHOLE thought, not this one sentence (AC-88). With a
            // single final the ledger's text IS `trimmed` — which is why
            // the common path is byte-for-byte what it was (D-040 F-5).
            await openGeneration(of: ledger.text, turn: turn,
                                 forwardingInto: &group, via: input)

        case .failed(let failure, let utterance, _):
            // The user's utterance itself failed to become text: the turn
            // ends as an event, the loop lives on (AC-65's transcription arm).
            guard let live = current, state == .listening, live.utterance == utterance
            else {
                if utterance > lastOnset {
                    pendingTranscripts[utterance] = event
                }
                return
            }
            failTurn(live.turn, with: .transcriptionFailed(failure))

        case .partial, .truncated:
            break   // hypotheses and ceilings are the session's story
        }
    }

    // MARK: - the reply gate (AC-81) and the one generation opener

    /// The gate's knock. Three doors, all checked in this same actor step:
    /// the turn ticket, the listening state, and the utterance the gate was
    /// armed for. A killed reply fails the pending check; a resumed user
    /// fails the utterance door; a barged turn fails the ticket. Any miss
    /// means the expiry lands in silence — exactly what AC-81 promises.
    private func handleGateExpired(
        turn: Int, utterance: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        guard let live = current, live.turn == turn, state == .listening,
              live.utterance == utterance, live.replyArmed
        else { return }
        current?.replyArmed = false
        transition(to: .thinking, turn: turn)
        // Built HERE, not when the gate was armed: anything the speaker
        // added during the gate belongs to the same thought.
        await openGeneration(of: ledger.text, turn: turn, forwardingInto: &group, via: input)
    }

    /// Opens the generator for a turn already in `thinking` — the single
    /// path, whether the gate was zero or just expired.
    private func openGeneration(
        of text: String, turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        do {
            let run = try await replyGenerator.openReply(to: text)
            // Reentrancy law: a barge or stop() may have run while we
            // awaited. The ticket answers.
            guard !isStopped, current?.turn == turn else {
                await run.cancel()
                return
            }
            current?.replyRun = run
            group.addTask {
                for await update in run.updates {
                    input.yield(.reply(turn: turn, update))
                }
            }
        } catch {
            // THE REENTRANCY LAW, ON THE FAILURE PATH — the arm the 4d
            // review found unguarded. `interrupt()` can land while
            // `openReply` is suspended, and unlike `stop()` it also drives
            // the state to `.idle`. Failing again from there is an illegal
            // `.idle → .idle` transition AND a second terminal event for a
            // turn that is already dead. The ticket answers, as always.
            guard !isStopped, current?.turn == turn else { return }
            if let failure = error as? TurnFailure {
                failTurn(turn, with: failure)
            } else {
                failTurn(turn, with: .generationFailed(String(describing: error)))
            }
        }
    }

    // MARK: - reply updates (the ticket's door, generation side)

    private func handleReply(
        _ update: ReplyUpdate,
        turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        // THE TICKET: checked in the same actor step that could retire it.
        // A dead turn's tokens stop at this line — defiant stages included.
        guard let live = current, live.turn == turn else { return }

        switch update {
        case .token(let token):
            // A defiant token AFTER the reply finished: the sentence is
            // over; late words are noise, not speech (review finding).
            guard !live.tokensFinished else { return }
            broadcast.publish(.replyToken(token, turn: turn))
            if live.synthesisRun == nil {
                // The first token opens the mouth.
                do {
                    let run = try await synthesizer.openUtterance()
                    // Reentrancy law: re-check the ticket after the await.
                    guard !isStopped, current?.turn == turn else {
                        await run.cancel()
                        return
                    }
                    current?.synthesisRun = run
                    group.addTask {
                        for await synthUpdate in run.updates {
                            input.yield(.synthesis(turn: turn, synthUpdate))
                        }
                    }
                    await run.feed(token)
                } catch {
                    // Same law, same reason (the review's second critical,
                    // and the likelier one in the field): an iOS
                    // interruption lands exactly while the mouth is being
                    // opened. If the ticket died in that window the turn
                    // is already finished — failing it again would be
                    // `.idle → .idle`.
                    guard !isStopped, current?.turn == turn else { return }
                    let dying = current
                    if let failure = error as? TurnFailure {
                        failTurn(turn, with: failure)
                    } else {
                        failTurn(turn, with: .synthesisFailed(String(describing: error)))
                    }
                    await dying?.replyRun?.cancel()
                }
            } else {
                await live.synthesisRun?.feed(token)
            }

        case .finished:
            if let synthesis = live.synthesisRun {
                guard !live.tokensFinished else { return }   // defiant double-finish
                current?.tokensFinished = true
                await synthesis.finishTokens()
            } else {
                // Zero tokens: nothing to say. The turn completes; the mouth
                // never opened, `speaking` never existed. The thought is
                // still ANSWERED — the generator saw all of it and chose
                // silence — so the ledger is emptied (D-040 F-2).
                current = nil
                ledger.clear()
                broadcast.publish(.turnCompleted(turn: turn))
                transition(to: .idle, turn: turn)
            }

        case .failed(let reason):
            let dying = current
            failTurn(turn, with: .generationFailed(reason))
            await dying?.synthesisRun?.cancel()
        }
    }

    // MARK: - synthesis updates (the ticket's door, speech side)

    private func handleSynthesis(_ update: SynthesisUpdate, turn: Int) async {
        guard let live = current, live.turn == turn else { return }   // the ticket

        switch update {
        case .started:
            // The evidence (D-029): sound is audible NOW. A defiant second
            // `started` fails the state guard and is noise, not a crash.
            guard state == .thinking else { return }
            transition(to: .speaking, turn: turn)
            // Turn latency (R2): final accepted → audible. The felt pause.
            if let reporter = latencyReporter, let clock, let start = live.thinkingStart {
                reporter.turnLatency(start.duration(to: clock.now), turn: turn)
            }

        case .finished:
            // THE ONE PLACE THE THOUGHT IS FORGOTTEN (D-040 F-2): the
            // reply was fully SPOKEN — evidence, not intent — so the
            // speaker got their answer. Every other ending keeps the
            // words, because in every other ending they went unanswered.
            current = nil
            ledger.clear()
            broadcast.publish(.turnCompleted(turn: turn))
            transition(to: .idle, turn: turn)
            await live.replyRun?.cancel()   // normally already done; reclaims
                                            // a defiant generator's resources

        case .failed(let reason):
            let dying = current
            failTurn(turn, with: .synthesisFailed(reason))
            await dying?.replyRun?.cancel()
            // AND THE MOUTH ITSELF. The reply's failure arm has always
            // cancelled the synthesis run (above); this arm never
            // cancelled anything of its own, so a mouth that reported
            // `.failed` was left running with `current` already nil —
            // unreachable for ever, and in the neural mouth's case still
            // holding a decode task that retains it. Harmless only while
            // Apple's mouth was the sole implementation, because it
            // never emits `.failed`.
            await dying?.synthesisRun?.cancel()
        }
    }

    /// The one place a turn dies of failure: event out, ticket dead, idle.
    private func failTurn(_ turn: Int, with failure: TurnFailure) {
        current = nil
        broadcast.publish(.turnFailed(failure, turn: turn))
        transition(to: .idle, turn: turn)
    }
}
