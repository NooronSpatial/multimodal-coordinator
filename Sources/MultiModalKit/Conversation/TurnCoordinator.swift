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
public actor TurnCoordinator {
    public struct Config: Sendable {
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int

        public init(listenerBufferCapacity: Int = Broadcast<TurnEvent>.defaultBufferCapacity) {
            self.listenerBufferCapacity = listenerBufferCapacity
        }
    }

    /// Everything that can wake the loop, in one type.
    private enum Input: Sendable {
        case audio(AudioEvent)
        case transcript(TranscriptEvent)
        case reply(turn: Int, ReplyUpdate)
        case synthesis(turn: Int, SynthesisUpdate)
        case audioEnded
        case transcriptsEnded
        case stopped
    }

    /// The live turn and its downstream chain. `current == nil` IS the
    /// retired ticket: every event stamped with a dead turn number stops at
    /// the guard that reads this.
    private struct LiveTurn {
        let turn: Int
        /// The input-side ticket (SPEC §31): the utterance whose final may
        /// drive this turn. Mirrored from the same event stream the session
        /// numbers from. A settled final from an EARLIER utterance (D-024)
        /// is comfort text for apps — never a reply trigger.
        var utterance: Int
        var replyRun: (any ReplyRun)?
        var synthesisRun: (any SynthesisRun)?
        var tokensFinished = false
    }

    /// AC-61: the legal-transition table. The funnel checks every change
    /// against THIS — no state write happens anywhere else.
    private static let legalTransitions: [TurnState: Set<TurnState>] = [
        .idle: [.listening],
        .listening: [.thinking, .idle],
        .thinking: [.speaking, .listening, .idle],
        .speaking: [.listening, .idle],
    ]

    private let replyGenerator: any ReplyGenerating
    private let synthesizer: any SpeechSynthesizing
    private let config: Config
    private let broadcast: Broadcast<TurnEvent>

    private var state: TurnState = .idle
    private var current: LiveTurn?
    private var nextTurn = 0
    /// Mirrors the session's utterance numbering: both count the same
    /// `speechStarted` events from the same pump stream.
    private var utteranceCount = 0
    /// Reorder tolerance: the coordinator's two input streams cross two
    /// forwarders, so a final can reach the merge BEFORE its own
    /// `speechStarted` (tests hit this window constantly; production hits
    /// it rarely but legally). A terminal transcript from the FUTURE — its
    /// utterance not yet counted — waits here and is consumed the moment
    /// its `speechStarted` arrives. Everything else that fails the input
    /// door is genuinely stale or dead, and stays dropped.
    private var pendingTranscripts: [Int: TranscriptEvent] = [:]
    private var merge: AsyncStream<Input>.Continuation?
    private var isStopped = false

    public init(
        replyGenerator: any ReplyGenerating,
        synthesizer: any SpeechSynthesizing,
        config: Config = Config()
    ) {
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
    }

    /// The current state, for late listeners: ask for NOW, then listen —
    /// events replay nothing (D-030, AC-67).
    public var currentState: TurnState { state }

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

            var audioOver = false
            var transcriptsOver = false
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
                case .audioEnded:
                    audioOver = true
                case .transcriptsEnded:
                    transcriptsOver = true
                case .stopped:
                    break loop
                }
                // Graceful end: no more triggers can arrive and no turn is
                // in flight — the loop's work is provably done.
                if audioOver && transcriptsOver && current == nil { break }
            }
            group.cancelAll()   // frees any forwarder stuck on a defiant stream
        }

        merge = nil
        broadcast.finish()
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
        guard case .speechStarted = event else { return }   // segments, ends,
                                                            // drops: not turn business
        let utterance = utteranceCount
        utteranceCount += 1

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
            // one's final is stale the moment this event exists.
            current?.utterance = utterance

        case .thinking, .speaking:
            // THE BARGE. Ticket first, in this same actor step: the old
            // turn is dead before anything awaits.
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
        }

        // The utterance is born — if its terminal transcript arrived early
        // (cross-stream reorder), consume it NOW, in arrival order.
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
            // THE INPUT DOOR: only the live turn, only while listening, and
            // only the CURRENT utterance's final. A stale settled final
            // (D-024) fails the third check and stays what it is — comfort
            // text for apps, never a reply trigger.
            guard let live = current, state == .listening, live.utterance == utterance
            else {
                if utterance >= utteranceCount {   // from the future: reorder,
                    pendingTranscripts[utterance] = event   // not staleness
                }
                return
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
            transition(to: .thinking, turn: turn)
            do {
                let run = try await replyGenerator.openReply(to: trimmed)
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
            } catch let failure as TurnFailure {
                failTurn(turn, with: failure)
            } catch {
                failTurn(turn, with: .generationFailed(String(describing: error)))
            }

        case .failed(let failure, let utterance, _):
            // The user's utterance itself failed to become text: the turn
            // ends as an event, the loop lives on (AC-65's transcription arm).
            guard let live = current, state == .listening, live.utterance == utterance
            else {
                if utterance >= utteranceCount {
                    pendingTranscripts[utterance] = event
                }
                return
            }
            failTurn(live.turn, with: .transcriptionFailed(failure))

        case .partial, .truncated:
            break   // hypotheses and ceilings are the session's story
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
                } catch let failure as TurnFailure {
                    let dying = current
                    failTurn(turn, with: failure)
                    await dying?.replyRun?.cancel()
                } catch {
                    let dying = current
                    failTurn(turn, with: .synthesisFailed(String(describing: error)))
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
                // never opened, `speaking` never existed.
                current = nil
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

        case .finished:
            current = nil
            broadcast.publish(.turnCompleted(turn: turn))
            transition(to: .idle, turn: turn)
            await live.replyRun?.cancel()   // normally already done; reclaims
                                            // a defiant generator's resources

        case .failed(let reason):
            let dying = current
            failTurn(turn, with: .synthesisFailed(reason))
            await dying?.replyRun?.cancel()
        }
    }

    /// The one place a turn dies of failure: event out, ticket dead, idle.
    private func failTurn(_ turn: Int, with failure: TurnFailure) {
        current = nil
        broadcast.publish(.turnFailed(failure, turn: turn))
        transition(to: .idle, turn: turn)
    }
}
