/// `TurnCoordinator` — the audio side: the onset door, THE BARGE WINDOW,
/// and the barge itself (D-031, D-071).

extension TurnCoordinator {
    func handleAudio(
        _ event: AudioEvent,
        arrived: C.Instant?,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        // 5d (D-133, D-134): an utterance ended — which one, and when it
        // ARRIVED. ② starts here, but only for the utterance whose final
        // drives the turn: the report checks the number (a person who went
        // on has a newer utterance, and this end is not its end).
        if case .speechEnded = event, let arrived, current != nil {
            current?.speechEnd = (utterance: lastOnset, at: arrived)
        }
        guard let opening = floorOpeningUtterance(for: event) else { return }
        let utterance = opening.utterance

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
            await barge(for: utterance, window: opening.window)
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

    /// Which utterance this audio event opens the floor for — `nil` when
    /// the event is not turn business, or when a candidate onset is still
    /// inside the window, proving itself.
    /// The utterance that takes the floor, if this event opens it — with
    /// how long its barge window held it back, on the audio timeline
    /// (5d, ⑦): zero for an onset that took the floor at once.
    private func floorOpeningUtterance(for event: AudioEvent) -> (utterance: Int, window: Duration)? {
        // THE BARGE WINDOW's other two events (D-071). A candidate onset
        // proves itself by CONTINUING, and abandons itself by stopping.
        // THE BARGE WINDOW (D-071). A candidate proves itself by
        // CONTINUING past its deadline, and abandons itself by stopping.
        if case .audioSegment(let chunk) = event {
            guard var candidate = pendingBarge else { return nil }
            // LOUDNESS, NOT DECLARED LENGTH (5d piece 3, R-4, F-38 A): the
            // pump sends a segment for every chunk through the hangover, so
            // "any segment past the deadline" measured loud part + hangover —
            // at a 700 ms hangover, every sound. Only a LOUD chunk proves a
            // person; a chunk the VAD said nothing about counts as loud, the
            // old rule.
            let loud = chunk.isLoud != false
            if loud, chunk.start >= candidate.onset {
                candidate.loudTime += chunk.start.duration(
                    to: AudioTime(frames: chunk.start.frames + chunk.frameCount, sampleRate: chunk.start.sampleRate))
                candidate.peak = max(candidate.peak, Self.rms(chunk.samples))
                pendingBarge = candidate
            }
            guard loud, chunk.start >= candidate.deadline else { return nil }
            report(candidate, verdictAt: chunk.start, accepted: true)
            // Still going at the far edge of the window — a person, not the
            // assistant's own tail. It falls straight through to the barge
            // below, which is the SAME code an immediate barge runs.
            //
            // It does not re-enter this function to do it: the first version
            // did, and re-arming happened before the state switch was
            // reached, so the candidate deferred itself forever and nothing
            // was ever barged.
            pendingBarge = nil
            return (candidate.utterance, candidate.onset.duration(to: chunk.start))
        }
        if case .speechEnded(let ended) = event {
            // It stopped before the window closed: the reply's own echo, by
            // the window's verdict (§43). Nothing dies — and its words, when
            // they arrive, are no one's (AC-358).
            if let candidate = pendingBarge {
                report(candidate, verdictAt: ended, accepted: false)
                abandonedUtterances = abandonedUtterances.filter { $0 > contextFloor }
                abandonedUtterances.insert(candidate.utterance)
            }
            pendingBarge = nil
            return nil
        }
        guard case .speechStarted(let started, let at) = event else { return nil }
        // segments, ends, drops: not turn business
        lastOnset = started
        // A candidate, not yet a barge. `.thinking` is deliberately not
        // included — nothing is playing, so nothing can be echoing, and
        // an onset then is a person.
        if case .speaking = state, config.bargeWindow > .zero {
            pendingBarge = PendingBarge(
                utterance: started,
                onset: at,
                deadline: at.advanced(by: config.bargeWindow),
                turn: current?.turn ?? nextTurn - 1)
            return nil
        }
        pendingBarge = nil
        return (started, .zero)
    }

    /// One candidate's verdict, to the reporter (5d piece 3, F-40 A).
    private func report(_ candidate: PendingBarge, verdictAt moment: AudioTime, accepted: Bool) {
        latencyReporter?.bargeCandidate(BargeCandidate(
            turn: candidate.turn, window: candidate.onset.duration(to: moment),
            loudTime: candidate.loudTime, peak: candidate.peak, accepted: accepted))
    }

    /// A chunk's loudness as RMS — the VAD's measure, for the report only.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// The barge: the one arm an immediate onset and a candidate that
    /// survived the window both fall into.
    private func barge(for utterance: Int, window: Duration) async {
        // THE BARGE. Ticket first, in this same actor step: the old
        // turn is dead before anything awaits.
        let bargeAccepted = clock?.now
        let dying = current
        let turn = nextTurn
        nextTurn += 1
        current = LiveTurn(turn: turn, utterance: utterance)
        if let dying {
            broadcast.publish(.turnBarged(turn: dying.turn))
            // THE BARGE IS REMEMBERED (4r, F-5 = A). A barge is the person
            // saying "I heard enough" — something WAS delivered, which is
            // the opposite of a failure, so D-040 F-2's reason for keeping
            // the words ("nothing answered them") does not apply here.
            //
            // The clear is CONDITIONAL, and that is the whole care in this
            // arm: a barge during `thinking`, before the first token, has
            // no answer half. The memory refuses it, `remember` says so,
            // and the words stay in the ledger to join the next thought.
            // Clearing unconditionally would make the person's question
            // vanish between two turns. (Since 5b, D-119: if a tool already
            // RAN, the act is the answer — the memory keeps the turn, marked
            // interrupted, and the words are answered by what was done.)
            if remember(dying, interrupted: true) { ledger.clear() }
        }
        transition(to: .listening, turn: turn)
        await dying?.replyRun?.cancel()      // optimization, after the
        await dying?.synthesisRun?.cancel()  // guarantee
        // Cancel latency (R2): barge accepted → both cancels
        // acknowledged. Belongs to the turn that died.
        if let reporter = latencyReporter, let clock, let bargeAccepted, let dying {
            let silence = bargeAccepted.duration(to: clock.now)
            reporter.cancelLatency(silence, turn: dying.turn)
            // …and the whole interruption (5d, D-133): the window the person
            // talked through, then that same silence.
            reporter.bargeTimeline(BargeTimeline(turn: dying.turn, window: window, silence: silence))
        }
    }
}

extension AudioTime {
    /// The time from `self` to `later` on the audio timeline — one pump,
    /// one sample rate (5d, the barge window's ⑦).
    func duration(to later: AudioTime) -> Duration {
        .nanoseconds(Int64((Double(later.frames - frames) / sampleRate * 1e9).rounded()))
    }
}
