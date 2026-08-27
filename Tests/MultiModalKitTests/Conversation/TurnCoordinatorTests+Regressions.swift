// `TurnCoordinatorTests`, continued: the review's regressions.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - the review's regressions (adversarial pass, 2026-08-14)

    @Test("REGRESSION: a final that beat its own onset is answered ONCE, never twice")
    func aFinalThatBeatItsOnsetIsAnsweredOnce() async {
        // The review's confirmed bug, reproduced. A final can reach the
        // merge BEFORE its own `speechStarted` (separate forwarders —
        // the coordinator documents this window). It was recorded into
        // the LIVE turn's thought AND stashed as a future trigger, so
        // after that turn completed and emptied the ledger, the replay
        // answered the very same sentence a second time.
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentUtterance == 0 })
            // Utterance 1's final overtakes its own onset.
            bench.transcripts.yield(.final("and what about Spain", utterance: 1, at: Self.t(96_000)))
            bench.transcripts.yield(.final("what is the capital of France", utterance: 0,
                                           at: Self.t(1_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            // Turn 0 is spoken in full, so its thought is answered and forgotten.
            bench.generator.emit(reply: 0, token: "answer")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until {
                bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            // Only NOW does the late onset arrive, releasing the stashed final.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96_000)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "what is the capital of France",
                "an utterance whose onset has not arrived is NOT part of this thought yet")
        #expect(bench.generator.record(ofReply: 1)?.transcript == "and what about Spain",
                "…and when its turn comes it is answered exactly once, not repeated")
    }
}
