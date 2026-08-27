// `TurnCoordinatorTests`, continued: the reply gate.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - the reply gate (AC-81, D-037 F-3: mechanism here, number with the app)

    // How these tests prove a NEGATIVE without counting iterations (the
    // project bans count-based waits, and the ManualClock's own `settle`
    // says the tests must never lean on it):
    //
    //   · "the gate has not fired yet" is a FACT, available the instant
    //     `advance` returns — advance wakes every due sleeper before it
    //     returns, so a still-parked sleeper means the deadline is still
    //     in the future. `sleeperCount` reads it directly.
    //   · "a knock was already processed" is proven by a CAUSAL BARRIER:
    //     the merged loop is FIFO, so arming a LATER gate and waiting for
    //     that (event-driven, via waitForSleepers) proves everything
    //     yielded earlier has been handled.
    //
    // No test here waits for "enough time" or "enough yields".

    @Test("The gate holds the generator shut, then expiry opens thinking at the exact instant")
    func gateExpiryOpensThinkingAtTheExactInstant() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter,
                          config: .init(replyGate: .milliseconds(500)))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "gated", at: 0)
            // The gate is ARMED — waited for event-driven, from the sleep's
            // own registration. (Advancing before it exists would let the
            // deadline be computed from already-advanced time.)
            #expect(await Self.parked(clock), "no gate armed on the clock")
            // 499 of 500 ms. `advance` wakes every DUE sleeper before it
            // returns, so a sleeper still parked here is proof the deadline
            // has not arrived — no settling, no counting.
            await clock.advance(by: .milliseconds(499))
            #expect(clock.sleeperCount == 1, "the gate fired before its deadline")
            #expect(bench.generator.repliesOpened == 0, "the gate leaked early")
            #expect(await bench.coordinator.currentState == .listening)

            await clock.advance(by: .milliseconds(1))     // exactly 500
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "expiry did not open the generator")
            #expect(await bench.coordinator.currentState == .thinking)

            bench.generator.emit(reply: 0, token: "tick")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        // The felt pause is honest: it starts at the FINAL, so the gate's
        // 500 ms belong to it — exactly, in mock time.
        #expect(reporter.turnLatencies.first ?? (.zero, -1) == (.milliseconds(500), 0),
                "the reported pause must include the gate the user waited through")
    }

    @Test("An onset during the gate kills the pending reply silently; the next final gates again")
    func onsetDuringGateKillsThePendingReplySilently() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter,
                          config: .init(replyGate: .milliseconds(500)))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the user was not done", at: 0)
            #expect(await Self.parked(clock), "no gate armed on the clock")
            await clock.advance(by: .milliseconds(200))
            // The user resumes: same turn keeps listening, the pending
            // reply dies with NO events — no thinking, no ghost turn.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 1 },
                    "the onset never reached the actor")
            await clock.advance(by: .seconds(10))         // the dead gate expires into nothing
            #expect(await bench.coordinator.currentState == .listening)

            // The user's REAL final gates again — and its arming is the
            // CAUSAL BARRIER: the loop is FIFO, so a second gate on the
            // clock proves the dead gate's knock was already handled.
            bench.transcripts.yield(.final("now I am done", utterance: 1, at: Self.t(96_000)))
            #expect(await Self.parked(clock), "no gate armed on the clock")
            #expect(bench.generator.repliesOpened == 0,
                    "a killed gate still opened the generator")
            await clock.advance(by: .milliseconds(500))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // AMENDED BY RULING (D-040 F-5). This once read
            // `== "now I am done"` with the reason "the generator must
            // open with the SECOND final's text" — and that sentence was
            // this milestone's bug, stated as a requirement. The gate's
            // job is unchanged and still proven above: the killed reply
            // opened NOTHING at its own expiry. What changed is that the
            // words the speaker said before the gate died are not thrown
            // away; they are part of the same thought.
            #expect(bench.generator.record(ofReply: 0)?.transcript
                    == "the user was not done now I am done",
                    "the killed reply's words were never answered, so they join the thought")

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let states = await bench.box.states()
        #expect(!states.dropFirst().contains(.listening),
                "the killed reply must not produce a second listening transition")
    }

    @Test("An onset one tick before expiry wins the race")
    func onsetOneTickBeforeExpiryWins() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter,
                          config: .init(replyGate: .milliseconds(500)))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "almost", at: 0)
            #expect(await Self.parked(clock), "no gate armed on the clock")
            await clock.advance(by: .milliseconds(499))
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(24_000)))
            // The onset must be IN before the last tick fires the gate.
            #expect(await Self.until { await bench.coordinator.currentUtterance == 1 },
                    "the onset was not processed before the deciding tick")
            await clock.advance(by: .milliseconds(1))      // the gate fires into a changed world
            // The barrier again: a second final arms a second gate, and its
            // appearance on the clock proves the first knock was handled.
            bench.transcripts.yield(.final("the real thing", utterance: 1, at: Self.t(48_000)))
            #expect(await Self.parked(clock), "no gate armed on the clock")
            #expect(bench.generator.repliesOpened == 0,
                    "the onset lost a race it arrived first for")
            #expect(await bench.coordinator.currentState == .listening)

            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    @Test("The default gate is zero — 4a byte for byte (the untouched suite is the proof; this pins the default)")
    func defaultGateIsZero() {
        #expect(TurnCoordinator<ContinuousClock>.Config().replyGate == .zero)
    }

    @Test("A stale final during the gate is dropped at the door; the armed reply survives it")
    func staleFinalDuringGateIsDroppedAndTheArmedReplySurvives() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter,
                          config: .init(replyGate: .milliseconds(500)))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Utterances 0..4 came and went before this bench's story; the
            // pump's numbering is monotonic, so the test starts at 5.
            bench.speak(utterance: 5, final: "armed", at: 0)
            #expect(await Self.parked(clock), "no gate armed on the clock")
            await clock.advance(by: .milliseconds(100))
            // A settled final from an EARLIER utterance (D-024): the input
            // door refuses it as a trigger — it must not disturb the armed
            // gate.
            //
            // This yield USED to be followed straight by the clock advance,
            // under the comment "the FIFO loop must handle it first". That
            // was WRONG, and 4c proved it: the transcript forwarder and the
            // gate's sleeper are independent tasks racing to reach the
            // merge, so their order was never guaranteed. The old assertion
            // could not see it (the stale final was dropped either way);
            // the ledger can, and the suite flaked once in ~15 runs until
            // this gate was put in. Chased, not retried.
            bench.transcripts.yield(.final("stale comfort text", utterance: 3, at: Self.t(10)))
            #expect(await Self.until {
                await bench.coordinator.currentContext.contains("stale comfort text") },
                "the stale final must be RECORDED before the gate fires — the fact, not a hope")
            // DOOR SENSITIVITY, RESTORED (review finding). The amendment
            // below replaced the one assertion that could see the input
            // door, leaving a test that passed with the door broken. THIS
            // is the door: an ACCEPTED stale final would open its reply
            // immediately, without waiting for the armed gate. Checked
            // before the clock moves, so only a refusal can be green.
            #expect(bench.generator.repliesOpened == 0,
                    "the stale final was accepted — it opened a reply without the gate")
            await clock.advance(by: .milliseconds(400))   // the gate completes
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            #expect(bench.generator.repliesOpened == 1,
                    "the stale final opened a reply of its own")
            // AMENDED BY RULING (D-040 F-5). This once read `== "armed"`.
            // The stale final still neither opens a reply of its own (the
            // assertion above) nor replaces the armed one — the door is
            // untouched. It now contributes its WORDS, in spoken order:
            // utterance 3 was said before utterance 5, so it leads.
            #expect(bench.generator.record(ofReply: 0)?.transcript == "stale comfort text armed",
                    "a stale final may not TRIGGER, but it is still something the speaker said")

            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    @Test("stop() during the gate: clean end, no generator, no sleeping child left behind")
    func stopDuringTheGateEndsClean() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter,
                          config: .init(replyGate: .milliseconds(500)))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "never spoken", at: 0)
            // PROVABLY armed before stop(), or the leak check below is vacuous.
            #expect(await Self.parked(clock), "no gate armed on the clock")
            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 0)
        #expect(clock.sleeperCount == 0, "the gate's sleeper survived stop()")
    }
}
