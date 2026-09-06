// `TurnCoordinatorTests`, continued: the transcript ledger.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - the transcript ledger (SPEC AC-87..AC-90, D-040)

    /// Drives the field scenario's shape: an onset, a SECOND onset before
    /// the first final arrives (so that first final is refused at the
    /// input door), then both finals. Event-gated at the point where the
    /// two streams must not race — the coordinator's own comment says a
    /// final can beat its onset, so nothing here may assume arrival order.
    private func speakTwoSentencesWithAPause(
        _ bench: Bench<ContinuousClock>, first: String, second: String
    ) async {
        bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
        #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })
        bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
        #expect(await Self.until { await bench.coordinator.currentUtterance == 1 },
                "the second onset must land before the finals, or the door is not exercised")
        // Same stream, so these two keep their order.
        bench.transcripts.yield(.final(first, utterance: 0, at: Self.t(1_000)))
        bench.transcripts.yield(.final(second, utterance: 1, at: Self.t(49_000)))
    }

    @Test("THE MILESTONE: a thought spoken in two sentences reaches the generator whole")
    func theWholeThoughtReachesTheGenerator() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            await speakTwoSentencesWithAPause(
                bench, first: "Do you hear me well?", second: "should I take a jacket?")
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript
                == "Do you hear me well? should I take a jacket?",
                "the refused final must contribute CONTENT — that is the whole milestone")
    }

    @Test("The refused final contributes content and still triggers nothing (AC-87)")
    func theRefusedFinalTriggersNothing() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            await speakTwoSentencesWithAPause(bench, first: "one", second: "two")
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 1,
                "two finals, ONE reply — a refused final must open no turn")
        let states = await bench.box.states()
        #expect(states == [.listening, .thinking],
                "the refused final must not add a transition — the trigger rules did not move")
    }

    @Test("A completed reply forgets the thought; the next turn starts clean (AC-89)")
    func completionForgetsTheThought() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the first thought", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "tick")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until {
                bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.speak(utterance: 1, final: "the second thought", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript == "the second thought",
                "a thought that was ANSWERED must not haunt the next turn")
    }

    @Test("A failed turn keeps its words — nothing answered them (AC-89)")
    func aFailedTurnKeepsItsWords() async {
        let bench = Bench(generator: ScriptedReplyGenerator(plans: [.failOnOpen("no model"), .manual()]),
                          synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the lost question", at: 0)
            #expect(await Self.until {
                await bench.box.events.contains(
                    .turnFailed(.generationFailed("no model"), turn: 0)) })

            bench.speak(utterance: 1, final: "asking again", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript == "the lost question asking again",
                "a failure never answered the words, so they must survive (D-040 F-2)")
    }

    /// **CHANGED BY D-089 (F-5 = A), and the old expectation is written
    /// down rather than quietly swapped.**
    ///
    /// Until 4r a barge left the words in the ledger, so the next thought
    /// read "the interrupted thought and the rest of it". That was right
    /// while there was nowhere else for them to go. Now they move into the
    /// conversation instead — the person heard part of an answer, so the
    /// exchange happened — and the next thought is only the new sentence.
    ///
    /// Nothing is lost: the assertion below checks BOTH halves, that the
    /// ledger let go and that the memory took it. A test that only checked
    /// the first would pass just as well if the words had vanished.
    @Test("A barge moves the thought into the conversation, not into the next question (D-089)")
    func aBargeCarriesTheThoughtForward() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the interrupted thought", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "answering")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96_000)))   // THE BARGE
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })
            bench.transcripts.yield(.final("and the rest of it", utterance: 1, at: Self.t(97_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript == "and the rest of it",
                "the barged thought was remembered, so it must not be re-asked (D-089)")
        #expect(bench.generator.record(ofReply: 1)?.history.map(\.said)
                == ["the interrupted thought"],
                "and it must be REMEMBERED — the ledger let go, so the memory took it")
        #expect(bench.generator.record(ofReply: 1)?.history.first?.interrupted == true,
                "marked, or the mind may say \"as I explained\" about half a sentence")
    }

    @Test("An empty final is NOT rescued into a reply by a full ledger (AC-87)")
    func anEmptyFinalIsNotRescuedByAFullLedger() async {
        // §46a finding 1: an empty decode is the signature of a
        // FRAGMENTED speaker, never of a finished one.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            await speakTwoSentencesWithAPause(bench, first: "words in the ledger", second: "   ")
            #expect(await Self.until { await bench.coordinator.currentState == .idle })
            await Self.settled()

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 0,
                "silence must not become a trigger just because earlier words exist")
    }

    @Test("stop() mid-accumulation ends clean and publishes nothing after (AC-90)")
    func stopMidAccumulationEndsClean() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 1 })
            bench.transcripts.yield(.final("recorded but never answered", utterance: 0,
                                           at: Self.t(1_000)))
            // DE-VACUIZED (review finding): this used to wait on `settled()`
            // — a count of yields, i.e. hope — and asserted nothing that
            // required the final to have been RECORDED. It was green with
            // the ledger deleted. Now it gates on the fact and proves the
            // accumulation it is named for actually happened first.
            #expect(await Self.until {
                await bench.coordinator.currentContext == "recorded but never answered" },
                "nothing was accumulated, so this test would prove nothing about stop()")

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 0)
        let events = await bench.box.events
        #expect(events == [.stateChanged(.listening, turn: 0)],
                "accumulating is silent: it publishes nothing of its own")
    }

    @Test("The context bound is the app's number, and its default is stated")
    func theContextBoundIsTheAppsNumber() {
        #expect(TurnCoordinator<ContinuousClock>.Config().maxContextPieces == 16)
    }

    @Test("A ZERO-TOKEN reply also forgets the thought — F-2's second clear site")
    func aZeroTokenReplyAlsoForgetsTheThought() async {
        // Review finding: D-040 F-2 names TWO clear sites and only the
        // spoken one was covered. The generator here sees the whole
        // thought and says nothing — which counts as answered.
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "a question with no answer", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.finish(reply: 0)                // finished with ZERO tokens
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })
            #expect(await bench.coordinator.currentContext == "",
                    "the generator saw the whole thought and chose silence — that is an answer")

            bench.speak(utterance: 1, final: "a fresh question", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 1)?.transcript == "a fresh question")
    }

    @Test("MEMBERSHIP (AC-86): partials, ceilings and failures put nothing in the thought")
    func onlyFinalsEnterTheThought() async {
        // Review finding: AC-86's membership rule was prose only — no test
        // ever yielded a .partial or .truncated to the coordinator, so
        // recording them would have left the whole suite green.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })
            bench.transcripts.yield(.partial("a guess in progress", utterance: 0, at: Self.t(500)))
            bench.transcripts.yield(.truncated(utterance: 0, at: Self.t(600)))
            bench.transcripts.yield(.final("the real words", utterance: 0, at: Self.t(1_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "the real words",
                "a hypothesis is not speech; only a FINAL is what the speaker said")
    }

    @Test("The app's context bound reaches the ledger and drops the oldest through the loop")
    func theContextBoundIsWiredThroughTheLoop() async {
        // Review finding: only the Config literal was pinned, so nothing
        // proved the number ever arrived, nor that F-4's anti-wedge bound
        // works through the coordinator.
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          config: .init(maxContextPieces: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            for utterance in 0...2 {
                bench.audio.yield(.speechStarted(utterance: utterance,
                                                 at: Self.t(utterance * 48_000)))
                #expect(await Self.until {
                    await bench.coordinator.currentUtterance == utterance })
            }
            bench.transcripts.yield(.final("one", utterance: 0, at: Self.t(1_000)))
            bench.transcripts.yield(.final("two", utterance: 1, at: Self.t(49_000)))
            bench.transcripts.yield(.final("three", utterance: 2, at: Self.t(97_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "two three",
                "a bound of 2 must drop the oldest piece, all the way through the loop")
    }
}
