/// `TurnCoordinator` — the stage runs' updates: the ticket's door on the
/// generation side and on the speech side (D-031, AC-62).

extension TurnCoordinator {
    // MARK: - reply updates (the ticket's door, generation side)

    func handleReply(
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
            // ④ ends at the FIRST token (5d, D-133) — stamped before the
            // mouth is opened on it, so opening the mouth is ⑤'s time.
            if live.firstTokenAt == nil, let clock { current?.firstTokenAt = clock.now }
            // Remembered as it is born, from the tokens already passing
            // through here (AC-193/AC-195). A barge can land at any point
            // after this line, and whatever has accumulated by then is
            // exactly what the mind produced.
            current?.generated += token
            broadcast.publish(.replyToken(token, turn: turn))
            if live.synthesisRun == nil {
                // The first token opens the mouth.
                await openMouth(with: token, turn: turn,
                                forwardingInto: &group, via: input)
            } else {
                await live.synthesisRun?.feed(token)
            }

        case .toolRan(let use):
            // A record, after the fact (D-120): the mind ran the tool; the
            // turn only KEEPS what it did, to remember it with the words.
            // Kept for as long as the turn lives — even after the reply's
            // terminal, where a late TOKEN is noise: an act that happened
            // is not a word (the run passes records past its clock for the
            // same reason, D-119). A dead turn's record stopped at the
            // ticket above.
            current?.used.append(use)

        case .finished:
            // The stop reason is the TEXT caller's concern (4v); a spoken
            // reply ends the same way whether the model stopped or the
            // cap did — the barge-in is the voice path's ceiling.
            if let synthesis = live.synthesisRun {
                guard !live.tokensFinished else { return }   // defiant double-finish
                current?.tokensFinished = true
                await synthesis.finishTokens()
            } else {
                // Zero tokens: nothing to say. The turn completes; the mouth
                // never opened, `speaking` never existed. The thought is
                // still ANSWERED — the generator saw all of it and chose
                // silence — so the ledger is emptied (D-040 F-2).
                //
                // Nothing is remembered: an exchange with no answer is not
                // an exchange, and the memory refuses it on its own — unless
                // a tool ran, because an act is an answer (5b, D-119 F-14 A).
                // The attempt is made either way so this arm and the spoken
                // one say the same thing, and the rule lives in ONE place.
                remember(live, interrupted: false)
                current = nil
                ledger.clear()
                broadcast.publish(.turnCompleted(turn: turn))
                transition(to: .idle, turn: turn)
            }

        case .failed(let failure):
            let dying = current
            // THE TYPED VALUE goes where the description went (5c, D-128
            // F-23 A; AC-242 reversed in the open): a conversation can
            // switch on `.unexplained` exactly as a text caller does, and
            // the words are still the payload's `description`.
            failTurn(turn, with: .generationFailed(failure))
            await dying?.synthesisRun?.cancel()
        }
    }

    /// Opening the mouth for a turn that has just produced its first
    /// token — the one place a synthesis run is created.
    private func openMouth(
        with token: String,
        turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
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
    }

    // MARK: - synthesis updates (the ticket's door, speech side)

    func handleSynthesis(_ update: SynthesisUpdate, turn: Int) async {
        guard let live = current, live.turn == turn else { return }   // the ticket

        switch update {
        case .started:
            // The evidence (D-029): sound is audible NOW. A defiant second
            // `started` fails the state guard and is noise, not a crash.
            guard state == .thinking else { return }
            transition(to: .speaking, turn: turn)
            // Turn latency (R2): final accepted → audible. The felt pause.
            if let reporter = latencyReporter, let clock, let start = live.thinkingStart {
                let now = clock.now          // ONE reading: the timeline sums to this exactly
                reporter.turnLatency(start.duration(to: now), turn: turn)
                // …and the same pause, stage by stage, reported HERE at the
                // first sound (5d, D-133): a reply cut after it still counts.
                if let opened = live.openedAt, let token = live.firstTokenAt {
                    let end = live.speechEnd.flatMap { $0.utterance == live.utterance ? $0.at : nil }
                    reporter.turnTimeline(TurnTimeline(
                        turn: turn,
                        earFinish: end.map { $0.duration(to: start) },
                        gate: start.duration(to: opened),
                        firstToken: opened.duration(to: token),
                        firstSound: token.duration(to: now)))
                }
            }

        case .finished:
            // THE ONE PLACE THE THOUGHT IS FORGOTTEN (D-040 F-2): the
            // reply was fully SPOKEN — evidence, not intent — so the
            // speaker got their answer.
            //
            // 4r adds the other half of that sentence: forgotten by the
            // LEDGER, remembered by the conversation. The clear is still
            // unconditional here — a completed turn's words are answered
            // whether or not the memory kept them (since D-096 it always
            // keeps a whole exchange; only a half-turn or a switched-off
            // memory refuses, and neither is a reason to re-ask the person).
            remember(live, interrupted: false)
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
}
