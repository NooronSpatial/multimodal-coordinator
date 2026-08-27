// `TurnCoordinatorTests`, continued: empty finals, stage failures, the
// zero-token reply, and the funnel audit.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - empty finals and failures (AC-64, AC-65)

    @Test("A whitespace-only final produces no reply: back to idle, generator untouched")
    func whitespaceFinalMakesNoTurn() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "   \n ", at: 0)
            #expect(await Self.until { await bench.box.events.contains(.stateChanged(.idle, turn: 0)) },
                    "a blank final must return to idle")

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 0, "the generator must never be opened (AC-64)")
        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.idle, turn: 0)
        ])
    }

    @Test("A generator failure ends the turn, not the coordinator; the next turn runs clean")
    func generatorFailureEndsOnlyTheTurn() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.failOnOpen("no model"), .manual()]),
            synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "doomed", at: 0)
            #expect(await Self.until { await bench.box.events.contains(
                .turnFailed(.generationFailed("no model"), turn: 0))
            }, "the failure must surface as a turn event, reason intact")

            // The next turn is untouched by the corpse.
            bench.speak(utterance: 1, final: "healthy", at: 9600)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "fine")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let events = await bench.box.events
        #expect(events.contains { if case .turnFailed(_, 0) = $0 { true } else { false } })
        #expect(events.contains(.turnCompleted(turn: 1)))
    }

    /// BLOCKER 1'S SECOND HALF (D-051). This test asserted the reply run
    /// was cancelled and said nothing about THE MOUTH — so the arm that
    /// leaves a failed mouth running was unpinned while the fix for it was
    /// already in the code. Harmless only while Apple's mouth was the sole
    /// implementation, because it never emits `.failed`; the neural mouth
    /// does, and a mouth left running still holds a decode task that
    /// retains it, unreachable for ever with `current` already nil.
    @Test("A synthesizer failure mid-speech ends the turn; the reply run AND the mouth are cancelled")
    func synthesizerFailureEndsTheTurn() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "speak up", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "loud")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            bench.synthesizer.reportFailed(utterance: 0, reason: "audio route died")
            #expect(await Self.until { await bench.box.events.contains(
                .turnFailed(.synthesisFailed("audio route died"), turn: 0)) })
            #expect(await Self.until { bench.generator.record(ofReply: 0)?.cancelled == true },
                    "the reply run must be cancelled with its turn")
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.cancelled == true },
                    "and the MOUTH that failed must be cancelled too, or it is left running and unreachable")

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.coordinator.currentState == .idle)
    }

    // MARK: - the zero-token reply

    @Test("A reply that finishes with zero tokens completes the turn; speaking never happens")
    func zeroTokenReplyCompletesWithoutSpeaking() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "say nothing", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.finish(reply: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.synthesizer.utterancesOpened == 0, "nothing to say — the mouth stays shut")
        #expect(await bench.box.states() == [.listening, .thinking, .idle])
    }

    // MARK: - the funnel audit (AC-61)

    @Test("Every adjacent state pair across a multi-turn run is in the legal table")
    func funnelAuditOverMultiTurnRun() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(), .failOnOpen("x"), .manual()]),
            synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Turn 0: full happy turn.
            bench.speak(utterance: 0, final: "first", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "a")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            // Turn 1: generation fails on open.
            bench.speak(utterance: 1, final: "second", at: 48000)
            #expect(await Self.until { await bench.box.events.contains {
                if case .turnFailed(_, 1) = $0 { true } else { false }
            } })

            // Turn 2: barged mid-speaking, then turn 3 abandoned by stop().
            bench.speak(utterance: 2, final: "third", at: 96000)
            #expect(await Self.until { bench.generator.repliesOpened == 3 })
            bench.generator.emit(reply: 2, token: "b")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 2 })
            bench.synthesizer.reportStarted(utterance: 1)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })
            bench.audio.yield(.speechStarted(utterance: 3, at: Self.t(144000)))
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 2)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        let states = await bench.box.states()
        var previous = TurnState.idle   // the coordinator's birth state
        for state in states {
            #expect(Self.legalPairs[previous]?.contains(state) == true,
                    "illegal transition \(previous) → \(state)")
            previous = state
        }
    }
}
