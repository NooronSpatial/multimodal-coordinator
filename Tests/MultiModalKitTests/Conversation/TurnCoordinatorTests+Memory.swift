// `TurnCoordinatorTests`, continued: memory across turns (4r, D-088, D-089).

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    /// Drives one turn all the way to `turnCompleted` — final in, one
    /// token, the mouth opening, speech starting and finishing. Every step
    /// is gated on an observable fact, never on a delay.
    private func completeOneTurn(
        _ bench: Bench<ContinuousClock>,
        utterance: Int, saying said: String, answering replied: String, at frames: Int
    ) async {
        bench.speak(utterance: utterance, final: said, at: frames)
        #expect(await Self.until { bench.generator.repliesOpened == utterance + 1 })
        bench.generator.emit(reply: utterance, token: replied)
        #expect(await Self.until { bench.synthesizer.utterancesOpened == utterance + 1 })
        bench.synthesizer.reportStarted(utterance: utterance)
        bench.generator.finish(reply: utterance)
        #expect(await Self.until {
            bench.synthesizer.record(ofUtterance: utterance)?.tokensFinished == true })
        bench.synthesizer.reportFinished(utterance: utterance)
        #expect(await Self.until {
            await bench.box.events.contains(.turnCompleted(turn: utterance)) })
    }

    // MARK: - the milestone (AC-190, AC-191)

    /// **THE MILESTONE.** Two turns, and the second one can see the first —
    /// both halves of it, still apart.
    ///
    /// The second assertion is the one that would catch a seam quietly
    /// flattened back to a string: a history whose `replied` is empty, or
    /// whose words have been glued onto `transcript`, fails here and
    /// passes every other test in this file.
    @Test("THE MILESTONE: the second turn is shown the first, in roles (AC-190/AC-191)")
    func theSecondTurnSeesTheFirst() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            await completeOneTurn(bench, utterance: 0,
                                  saying: "what is Swift?",
                                  answering: "A programming language.", at: 0)
            bench.speak(utterance: 1, final: "who made it?", at: 96_000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let second = bench.generator.record(ofReply: 1)
        #expect(second?.transcript == "who made it?",
                "the thought being answered NOW is only the new sentence")
        #expect(second?.history.count == 1)
        #expect(second?.history.first?.said == "what is Swift?")
        #expect(second?.history.first?.replied == "A programming language.",
                "the mind's own words, kept apart from the person's — F-1 = B's whole point")
        #expect(second?.history.first?.interrupted == false)
    }

    /// AC-195. One event, both effects: the arm that forgets is the arm
    /// that remembers. A handover split across two places is a handover
    /// with a window in it where the words are in neither.
    @Test("completion forgets and remembers in the same step (AC-195)")
    func completionForgetsAndRemembersTogether() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            await completeOneTurn(bench, utterance: 0,
                                  saying: "good morning", answering: "Morning!", at: 0)

            #expect(await bench.coordinator.currentContext.isEmpty,
                    "the ledger let go — the thought was answered")
            #expect(await bench.coordinator.currentMemory.count == 1,
                    "and the conversation took it — not lost between the two")

            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    // MARK: - what is NOT remembered (AC-194, and F-5's trap)

    /// AC-194. A failure delivered nothing, so D-040 F-2 still rules: the
    /// words stay in the ledger and go out again with the next thought.
    ///
    /// The second assertion is the one that matters — if the turn were
    /// ALSO remembered, the mind would receive "the lost question" twice,
    /// once as history and once inside the new transcript, and answer it
    /// twice.
    @Test("a failed turn is never remembered, and keeps its words (AC-194)")
    func aFailedTurnIsNotRemembered() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.failOnOpen("no model"), .manual()]),
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

        let second = bench.generator.record(ofReply: 1)
        #expect(second?.transcript == "the lost question asking again",
                "nothing answered them, so the ledger keeps them (D-040 F-2, untouched)")
        #expect(second?.history.isEmpty == true,
                "and the memory must NOT also hold them — the same words twice is two answers")
    }

    /// **F-5 = A'S TRAP, PINNED.** A barge during `thinking`, before the
    /// first token exists.
    ///
    /// There is no answer half, so the memory refuses the exchange. If the
    /// ledger cleared anyway — the obvious way to write F-5 = A — the
    /// person's question would vanish between two turns and no other test
    /// here would notice. The rule the coordinator implements instead is
    /// "the ledger forgets exactly what the memory took", and this is the
    /// case that tells the two apart.
    @Test("a barge before the first token loses nothing (F-5 = A)")
    func aBargeBeforeTheFirstTokenLosesNothing() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the question nobody answered", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            #expect(await bench.coordinator.currentState == .thinking,
                    "no token has been emitted — the mouth has not opened")

            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96_000)))   // THE BARGE
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })
            bench.transcripts.yield(.final("never mind", utterance: 1, at: Self.t(97_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let second = bench.generator.record(ofReply: 1)
        #expect(second?.history.isEmpty == true,
                "half an exchange is not an exchange — the memory must refuse it")
        #expect(second?.transcript == "the question nobody answered never mind",
                "so the words stay in the ledger, exactly as before 4r")
    }

    /// A reply of zero tokens is not an exchange either — the mind saw the
    /// whole thought and chose silence. The ledger still clears, because
    /// the thought WAS answered (D-040 F-2's own reading of this arm), and
    /// the memory simply has nothing to hold.
    @Test("a reply of no tokens is answered, and not remembered")
    func aSilentReplyIsNotRemembered() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "say nothing", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.finish(reply: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            #expect(await bench.coordinator.currentContext.isEmpty)
            #expect(await bench.coordinator.currentMemory.isEmpty)

            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    // MARK: - where the conversation ends (F-4 = A)

    /// F-4 = A. One `start()`…`stop()` is one conversation. The boundary a
    /// person can SEE is the only kind they can trust.
    @Test("stop() ends the conversation's memory (F-4 = A)")
    func stopEndsTheMemory() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            await completeOneTurn(bench, utterance: 0,
                                  saying: "remember this", answering: "Noted.", at: 0)
            #expect(await bench.coordinator.currentMemory.count == 1)

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.coordinator.currentMemory.isEmpty,
                "the session closed, so the conversation did")
    }

    /// The app's earlier boundary, and the line it must not cross: forget
    /// the conversation, never the sentence the person is still saying.
    @Test("clearMemory() forgets the past and leaves the thought alone")
    func clearingMemoryLeavesTheThoughtAlone() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            await completeOneTurn(bench, utterance: 0,
                                  saying: "the old topic", answering: "Answered.", at: 0)

            // A new thought is on the wire but not yet answered.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96_000)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 1 })
            bench.audio.yield(.speechStarted(utterance: 2, at: Self.t(144_000)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 2 })
            bench.transcripts.yield(.final("mid sentence", utterance: 1, at: Self.t(97_000)))
            #expect(await Self.until {
                await bench.coordinator.currentContext == "mid sentence" })

            await bench.coordinator.clearMemory()
            #expect(await bench.coordinator.currentMemory.isEmpty)
            #expect(await bench.coordinator.currentContext == "mid sentence",
                    "the thought in flight is the person's, not the conversation's")

            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }
}
