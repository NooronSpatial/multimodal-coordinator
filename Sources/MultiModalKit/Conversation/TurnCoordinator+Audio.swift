/// `TurnCoordinator` — the audio side: the onset door, THE BARGE WINDOW,
/// and the barge itself (D-031, D-071).

extension TurnCoordinator {
    func handleAudio(
        _ event: AudioEvent,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        guard let utterance = floorOpeningUtterance(for: event) else { return }

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
            await barge(for: utterance)
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
    private func floorOpeningUtterance(for event: AudioEvent) -> Int? {
        // THE BARGE WINDOW's other two events (D-071). A candidate onset
        // proves itself by CONTINUING, and abandons itself by stopping.
        // THE BARGE WINDOW (D-071). A candidate proves itself by
        // CONTINUING past its deadline, and abandons itself by stopping.
        if case .audioSegment(let chunk) = event {
            guard let candidate = pendingBarge,
                  chunk.start >= candidate.deadline else { return nil }
            // Still going at the far edge of the window — a person, not the
            // assistant's own tail. It falls straight through to the barge
            // below, which is the SAME code an immediate barge runs.
            //
            // It does not re-enter this function to do it: the first version
            // did, and re-arming happened before the state switch was
            // reached, so the candidate deferred itself forever and nothing
            // was ever barged.
            pendingBarge = nil
            return candidate.utterance
        }
        if case .speechEnded = event {
            // It stopped before the window closed. 339–520 ms is the leak's
            // entire measured range (§43); nothing dies.
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
                deadline: at.advanced(by: config.bargeWindow))
            return nil
        }
        pendingBarge = nil
        return started
    }

    /// The barge: the one arm an immediate onset and a candidate that
    /// survived the window both fall into.
    private func barge(for utterance: Int) async {
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
}
