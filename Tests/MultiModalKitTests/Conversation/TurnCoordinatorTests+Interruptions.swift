// `TurnCoordinatorTests`, continued: interruptions, and the 4d review's
// criticals around them.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - interruptions (SPEC AC-94, D-042 F-3 and F-5)

    @Test("An interruption ends the live turn like a failure — not a barge")
    func interruptionEndsTheTurnLikeAFailure() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "a question the phone will interrupt", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "answering")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            await bench.coordinator.interrupt()
            #expect(await Self.until { await bench.coordinator.currentState == .idle })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        // THE MOUTH MUST STOP. The 4d review found the whole interruption
        // suite asserting events, states and ledger contents while never
        // once checking that the stages were cancelled — so deleting both
        // cancels from interrupt() passed every test, with a phone that
        // keeps talking through a call.
        #expect(bench.synthesizer.record(ofUtterance: 0)?.cancelled == true,
                "the platform took the audio and the mouth was never told")
        #expect(bench.generator.record(ofReply: 0)?.cancelled == true,
                "the generator kept producing for a turn nobody can hear")

        let events = await bench.box.events
        #expect(events.contains(.turnFailed(.interrupted, turn: 0)),
                "the platform took the audio — that is a failure, and it must be named")
        #expect(!events.contains(.turnBarged(turn: 0)),
                "nobody spoke: calling this a barge would corrupt the event for every app")
        #expect(!events.contains(.turnCompleted(turn: 0)))
        let states = await bench.box.states()
        #expect(states == [.listening, .thinking, .speaking, .idle],
                "idle, never listening — listening would claim a ghost utterance (D-033)")
    }

    @Test("A dead turn cannot speak after an interruption — defiant stages included")
    func nothingSurvivesAnInterruption() async {
        let bench = Bench(generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true)]),
                          synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "doomed by a phone call", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            await bench.coordinator.interrupt()
            #expect(await Self.until { await bench.coordinator.currentState == .idle })

            // The defiant generator keeps talking after cancel. The ticket
            // is the guarantee, not the cancel.
            bench.generator.forceToken(reply: 0, token: "ghost")
            bench.generator.forceFinished(reply: 0)
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let events = await bench.box.events
        #expect(!events.contains(where: { if case .replyToken = $0 { true } else { false } }),
                "a dead turn's token reached a listener")
        #expect(!events.contains(.turnCompleted(turn: 0)))
    }

    @Test("The interrupted thought SURVIVES — nothing answered it (D-040 F-2 inherited)")
    func anInterruptionKeepsTheWords() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the words the call interrupted", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            await bench.coordinator.interrupt()
            #expect(await Self.until { await bench.coordinator.currentState == .idle })
            #expect(await bench.coordinator.currentContext == "the words the call interrupted",
                    "an interruption never answered them, so they must still be there")

            bench.speak(utterance: 1, final: "and what I said after", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript
                == "the words the call interrupted and what I said after")
    }

    @Test("resume() forgets the thought — a call is a break in the conversation (F-5)")
    func resumingForgetsTheThought() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "should I book a table for", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            await bench.coordinator.interrupt()
            #expect(await Self.until { await bench.coordinator.currentState == .idle })

            await bench.coordinator.resume()          // the app decides to listen again
            #expect(await bench.coordinator.currentContext == "",
                    "a pre-call fragment must not join a post-call sentence")

            bench.speak(utterance: 1, final: "what is the weather", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript == "what is the weather",
                "the thought after a resume starts empty")
    }

    @Test("Interrupting while idle publishes nothing at all")
    func interruptingWhileIdleIsSilent() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            await bench.coordinator.interrupt()       // no turn is alive
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.box.events.isEmpty,
                "there was no turn to end — an interruption must invent nothing")
    }

    // MARK: - the 4d review's criticals (adversarial pass, 2026-08-15)

    @Test("CRITICAL: a generator that throws AFTER an interruption must not fail the turn twice")
    func aGeneratorThrowingAfterAnInterruptionFailsNothing() async {
        // The window: the coordinator is suspended inside
        // `await replyGenerator.openReply(...)` when the platform takes the
        // audio away. interrupt() retires the ticket AND drives the state
        // to .idle — it is the first path in the repo to do both from
        // outside the merge loop. The catch arms then called failTurn
        // regardless, which is .idle → .idle: not in the legal table.
        let bench = Bench(generator: ScriptedReplyGenerator(plans: [.blockThenFailOnOpen("late")]),
                          synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the doomed question", at: 0)
            // The generator is now HELD inside openReply.
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            #expect(await Self.until { await bench.coordinator.currentState == .thinking })

            await bench.coordinator.interrupt()      // the phone rings
            #expect(await Self.until { await bench.coordinator.currentState == .idle })

            bench.generator.releaseOpen()            // …and only now does it throw
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let failures = await bench.box.events.filter {
            if case .turnFailed = $0 { true } else { false }
        }
        #expect(failures == [.turnFailed(.interrupted, turn: 0)],
                "the interruption is the ONE failure; the late throw belongs to a dead turn")
        let states = await bench.box.states()
        #expect(states == [.listening, .thinking, .idle],
                "a second failTurn would transition .idle → .idle, which the table forbids")
    }

    @Test("CRITICAL: a synthesizer that throws AFTER an interruption must not fail the turn twice")
    func aSynthesizerThrowingAfterAnInterruptionFailsNothing() async {
        // The same window on the speech side, and the likelier one in the
        // field: the mouth is being opened at the exact moment iOS takes
        // the audio away.
        let bench = Bench(generator: .manual(replies: 1),
                          synthesizer: ScriptedSynthesizer(plans: [.blockThenFailOnOpen("late")]))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "a question about to be cut off", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "first")     // opens the mouth…
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })

            await bench.coordinator.interrupt()                // …the phone rings
            #expect(await Self.until { await bench.coordinator.currentState == .idle })

            bench.synthesizer.releaseOpen()                    // …and only now it throws
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let failures = await bench.box.events.filter {
            if case .turnFailed = $0 { true } else { false }
        }
        #expect(failures == [.turnFailed(.interrupted, turn: 0)],
                "the mouth's late failure belongs to a turn that is already dead")
    }

    @Test("A pre-interruption final arriving AFTER resume must not rejoin the thought")
    func aLateFinalCannotRejoinAfterResume() async {
        // Resuming forgets the thought (F-5). But forgetting is not
        // fencing: the recogniser can flush a final for speech from BEFORE
        // the call, and it arrives into a ledger that was just cleared —
        // so the pre-call fragment joins the post-call sentence anyway,
        // which is the exact nonsense F-5 was ruled to prevent.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })

            await bench.coordinator.interrupt()          // the phone rings mid-sentence
            #expect(await Self.until { await bench.coordinator.currentState == .idle })
            await bench.coordinator.resume()             // the app decides to listen again
            #expect(await bench.coordinator.currentContext == "")

            // The recogniser flushes what it had for the cut-off utterance.
            bench.transcripts.yield(.final("should I book a table for", utterance: 0,
                                           at: Self.t(960)))
            await Self.settled()
            #expect(await bench.coordinator.currentContext == "",
                    "a pre-interruption final must be FENCED OUT, not merely forgotten")

            bench.speak(utterance: 1, final: "what is the weather", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "what is the weather")
    }

    @Test("A final STASHED before an interruption is not replayed after resume")
    func aStashedFinalIsNotReplayedAfterResume() async {
        // The second hole: a final that overtook its onset waits in the
        // reorder buffer. interrupt() and resume() never touch it, so the
        // next onset replays it into the fresh thought.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })
            // Utterance 1's final overtakes its own onset and is stashed.
            bench.transcripts.yield(.final("stashed before the call", utterance: 1,
                                           at: Self.t(96_000)))
            await Self.settled()

            await bench.coordinator.interrupt()
            #expect(await Self.until { await bench.coordinator.currentState == .idle })
            await bench.coordinator.resume()

            bench.speak(utterance: 1, final: "after the call", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "after the call",
                "the stashed pre-interruption words must die with the interruption")
    }

    @Test("run() returns after an interruption even when the inputs ended first")
    func runReturnsAfterAnInterruptionOnDrainedInputs() async {
        // The graceful-end check sits at the BOTTOM of the merge loop, so
        // it is only re-read when a new item arrives. Every other path
        // that retires the ticket runs INSIDE the loop; interrupt() is the
        // first that does it from outside — so with both streams already
        // ended, nothing wakes the loop and run() never returns.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()
        let returned = Collected()

        await withTaskGroup(of: Void.self) { group in
            let coordinator = bench.coordinator
            group.addTask { for await event in listener.events { await returned.append(event) } }
            let audio = bench.audioEvents
            let transcripts = bench.transcriptEvents
            group.addTask {
                await coordinator.run(audio: audio, transcripts: transcripts)
                await returned.append(.turnCompleted(turn: -1))   // the "run() returned" marker
            }

            bench.speak(utterance: 0, final: "a turn that outlives its inputs", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()                 // both streams end WHILE a turn is live
            await Self.settled()
            await bench.coordinator.interrupt()  // …and the ticket dies from outside the loop

            #expect(await Self.until { await returned.events.contains(.turnCompleted(turn: -1)) },
                    "run() never returned — the loop is parked on a stream that will never speak")
            await bench.coordinator.stop()
        }
    }
}
