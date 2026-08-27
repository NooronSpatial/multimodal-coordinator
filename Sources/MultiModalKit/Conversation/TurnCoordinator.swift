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
/// THE NUMBER 4k MEASURED, for an app that wants a barge window.
///
/// 600 ms, ruled by Ryad on this evidence (INSTRUMENTS §43): across six
/// field sessions every leak of the assistant's own voice died under 530 ms,
/// and every real utterance lasted over 930. This sits 80 ms clear of the
/// longest leak and 339 ms clear of the shortest speech.
///
/// A named constant rather than a library default: the app that owns a
/// device owns the policy (D-027).
public enum BargeWindow {
    public static let measured = Duration.milliseconds(600)
}

public actor TurnCoordinator<C: Clock> where C.Duration == Duration {
    /// Everything that can wake the loop, in one type.
    enum Input: Sendable {
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
    struct LiveTurn {
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
            .speaking: [.listening, .idle]
        ]
    }

    let replyGenerator: any ReplyGenerating
    /// THE HEALTH ROAD (D-059 = A). Optional like the clock: nil injected
    /// means byte-for-byte the pre-4f coordinator — measurement and
    /// monitoring are opt-in, never ambient (D-026/D-028 precedents).
    private let diagnostics: PipelineDiagnostics?
    let synthesizer: any SpeechSynthesizing
    let config: Config
    let broadcast: Broadcast<TurnEvent>
    /// The measurement pair (R2): both or neither. With no reporter the
    /// coordinator never reads a clock — clockless by default, like the
    /// session (D-011's spirit: time only where a consumer asked for it).
    let clock: C?
    let latencyReporter: (any LatencyReporter)?

    var state: TurnState = .idle
    var current: LiveTurn?
    var nextTurn = 0
    /// The newest utterance identity SEEN here (D-034). Identities are
    /// assigned by the pump and carried in the events — this is a record
    /// of what arrived, never a parallel count. The review proved parallel
    /// counters over drop-tolerant streams desync forever; a number read
    /// from the event cannot.
    var lastOnset = -1
    /// Reorder tolerance: the coordinator's two input streams cross two
    /// forwarders, so a final can reach the merge BEFORE its own
    /// `speechStarted` (tests hit this window constantly; production hits
    /// it rarely but legally). A terminal transcript from the FUTURE — its
    /// utterance not yet counted — waits here and is consumed the moment
    /// its `speechStarted` arrives. Everything else that fails the input
    /// door is genuinely stale or dead, and stays dropped.
    var pendingTranscripts: [Int: TranscriptEvent] = [:]
    /// What the speaker said, kept whole (AC-85, D-040). Actor-scoped on
    /// purpose, NOT turn-scoped: a turn dies for reasons that have
    /// nothing to do with the words — an empty decode (the field's most
    /// common ending), a failure, a barge — and in every one of those
    /// the speaker never got an answer. It is emptied on `turnCompleted`
    /// and nowhere else (F-2 = A).
    var ledger: TranscriptLedger
    /// Everything at or below this utterance belongs to a conversation
    /// that `resume()` ended. Set only there; it fences pre-interruption
    /// speech out of the fresh thought (the 4d review's finding).
    var contextFloor = -1
    private var merge: AsyncStream<Input>.Continuation?
    var isStopped = false
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
        latencyReporter: any LatencyReporter,
        diagnostics: PipelineDiagnostics? = nil
    ) {
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.clock = clock
        self.latencyReporter = latencyReporter
        self.diagnostics = diagnostics
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
        self.ledger = TranscriptLedger(maxPieces: config.maxContextPieces)
    }

    /// The everyday coordinator: fully clockless — no reporter, no clock,
    /// not even a clock READ. Measurement is opt-in, never ambient.
    public init(
        replyGenerator: any ReplyGenerating,
        synthesizer: any SpeechSynthesizing,
        config: Config = Config(),
        diagnostics: PipelineDiagnostics? = nil
    ) where C == ContinuousClock {
        precondition(config.replyGate == .zero,
                     "a reply gate needs time — use the clocked initializer")
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.clock = nil
        self.latencyReporter = nil
        self.diagnostics = diagnostics
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

            for await item in inputs {
                if isStopped { break }
                if await dispatch(item, forwardingInto: &group, via: input) { break }
                // Graceful end: no more triggers can arrive and no turn is
                // in flight — the loop's work is provably done.
                if isDrained { break }
            }
            group.cancelAll()   // frees any forwarder stuck on a defiant stream
        }

        merge = nil
        broadcast.finish()
    }

    /// One item off the merge, sent to its handler — the loop's body, and
    /// the only place an `Input` is read. Returns `true` for `.stopped`,
    /// the loop's one deliberate exit.
    private func dispatch(
        _ item: Input,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async -> Bool {
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
            return true
        }
        return false
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

    func transition(to newState: TurnState, turn: Int) {
        assert(Self.legalTransitions[state]?.contains(newState) == true,
               "illegal transition \(state) → \(newState)")
        state = newState
        broadcast.publish(.stateChanged(newState, turn: turn))
    }

    // MARK: - audio events (the barge lives here, D-031)

    /// An onset seen while speaking, waiting to prove it is a person.
    struct PendingBarge: Sendable {
        let utterance: Int
        /// The audio moment at which it becomes a barge.
        let deadline: AudioTime
    }
    var pendingBarge: PendingBarge?

    /// The one place a turn dies of failure: event out, ticket dead, idle.
    func failTurn(_ turn: Int, with failure: TurnFailure) {
        current = nil
        broadcast.publish(.turnFailed(failure, turn: turn))
        // THE HEALTH-SIDE RECORD (D-059 = A), published from the ONE
        // funnel every turn death passes through — so the mind's tripwire
        // alarm (D-058's promise, which the 4f review proved unbuilt)
        // cannot miss the road. Same fact, two audiences: the
        // conversation stream serves whoever follows THIS conversation;
        // this serves whoever watches the pipeline's wellbeing across all
        // of them.
        diagnostics?.noteTurnFailed(turn: turn, failure: failure)
        transition(to: .idle, turn: turn)
    }
}
