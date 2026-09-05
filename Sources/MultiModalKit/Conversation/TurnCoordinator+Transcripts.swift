/// `TurnCoordinator` — the transcript side: the input-side ticket's door
/// (D-024, D-034), the reply gate (AC-81), and the one generation opener.

extension TurnCoordinator {
    // MARK: - transcript events (the input-side ticket's door)

    func handleTranscript(
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
    func handleGateExpired(
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
    func openGeneration(
        of text: String, turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        do {
            // WHAT THE MIND IS GIVEN (4r, F-1 = B): this thought, and the
            // bounded past with the halves kept apart. Built HERE rather
            // than carried from the gate, for `handleGateExpired`'s reason
            // one line up — anything that arrived in the meantime belongs.
            let run = try await replyGenerator.openReply(
                to: ReplyContext(transcript: text, history: memory.turns))
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
}
