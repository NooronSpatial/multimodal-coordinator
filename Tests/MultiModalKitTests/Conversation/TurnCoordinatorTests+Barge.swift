// `TurnCoordinatorTests`, continued: the happy turn, barge-in in every
// phase, and the input-side ticket.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - the happy turn (AC-61, AC-70's shape)

    @Test("One full turn: listening → thinking → speaking → idle, tokens included, exact sequence")
    func happyTurnExactSequence() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "turn on the lights", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "the final must open a reply")
            #expect(bench.generator.record(ofReply: 0)?.transcript == "turn on the lights")

            bench.generator.emit(reply: 0, token: "Sure,")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 },
                    "the first token must open the mouth")
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking },
                    "speaking must follow the synthesizer's evidence, not assumption")

            bench.generator.emit(reply: 0, token: "done.")
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.fedTokens.count == 2 })
            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true },
                    "reply finished must finish the synthesizer's tokens")
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("Sure,", turn: 0),
            .stateChanged(.speaking, turn: 0),
            .replyToken("done.", turn: 0),
            .turnCompleted(turn: 0),
            .stateChanged(.idle, turn: 0)
        ])
    }

    // MARK: - barge-in in every phase (AC-62, AC-63)

    @Test("Barge-in during thinking, before any token: the dead turn's ghost tokens never surface")
    func bargeDuringThinkingBeforeTokens() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true), .manual()]),
            synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "first question", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            // The user barges while the generator is still silent.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { await bench.coordinator.currentState == .listening })
            #expect(await Self.until { bench.generator.record(ofReply: 0)?.cancelled == true })

            // The DEFIANT generator emits into its dead turn — real ghosts.
            bench.generator.forceToken(reply: 0, token: "ghost")
            bench.generator.forceFinished(reply: 0)

            // The new turn completes; its events prove the ghosts were processed.
            bench.transcripts.yield(.final("second question", utterance: 1, at: Self.t(10560)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "answer")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        // AC-63: the EXACT sequence — order- and duplicate-proof. The
        // ghosts are provably never published, so this is deterministic.
        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .turnBarged(turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .replyToken("answer", turn: 1),
            .stateChanged(.speaking, turn: 1),
            .turnCompleted(turn: 1),
            .stateChanged(.idle, turn: 1)
        ])
    }

    @Test("Barge-in during speaking: defiant synthesizer's late 'finished' cannot complete the dead turn")
    func bargeDuringSpeaking() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true), .manual()]),
            synthesizer: ScriptedSynthesizer(plans: [.manual(ignoresCancel: true), .manual()]))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "tell me a story", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "Once")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            // Barge mid-speech.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48000)))
            #expect(await Self.until { await bench.coordinator.currentState == .listening })
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.cancelled == true })

            // Both dead stages defy: a ghost token AND a ghost 'finished'.
            bench.generator.forceToken(reply: 0, token: "upon")
            bench.synthesizer.forceUpdate(utterance: 0, .finished)

            // The new turn runs to completion.
            bench.transcripts.yield(.final("never mind", utterance: 1, at: Self.t(49000)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "OK.")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 2 })
            bench.synthesizer.reportStarted(utterance: 1)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 1)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 1)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        // AC-63: the EXACT sequence, ghost token and ghost 'finished'
        // provably absent — not merely "not contained".
        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("Once", turn: 0),
            .stateChanged(.speaking, turn: 0),
            .turnBarged(turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .replyToken("OK.", turn: 1),
            .stateChanged(.speaking, turn: 1),
            .turnCompleted(turn: 1),
            .stateChanged(.idle, turn: 1)
        ])
    }

    @Test("""
    Barge-in MID-GENERATION: tokens flowing, mouth open but still silent — \
    both runs die; a ghost 'started' cannot flip the new turn
    """)
    func bargeMidGeneration() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true), .manual()]),
            synthesizer: ScriptedSynthesizer(plans: [.manual(ignoresCancel: true), .manual()]))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "long story", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // A token flows and the mouth OPENS — but reports nothing yet:
            // the unique window where state is .thinking with a live synth.
            bench.generator.emit(reply: 0, token: "Once")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            #expect(await bench.coordinator.currentState == .thinking)

            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48000)))   // the barge
            #expect(await Self.until { bench.generator.record(ofReply: 0)?.cancelled == true })
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.cancelled == true },
                    "a mid-generation barge must kill the silent mouth too")

            // BOTH dead stages defy — including the never-before-forced
            // ghost 'started': if the ticket door leaks, it would flip the
            // NEW turn's thinking to speaking with nothing audible.
            bench.generator.forceToken(reply: 0, token: "upon")
            bench.synthesizer.forceUpdate(utterance: 0, .started)

            bench.transcripts.yield(.final("stop", utterance: 1, at: Self.t(49000)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "OK.")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 2 })
            bench.synthesizer.reportStarted(utterance: 1)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 1)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 1)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("Once", turn: 0),
            .turnBarged(turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .replyToken("OK.", turn: 1),
            .stateChanged(.speaking, turn: 1),
            .turnCompleted(turn: 1),
            .stateChanged(.idle, turn: 1)
        ], "speaking may appear ONLY for turn 1 — a ghost 'started' flipping a turn is the ticket door failing")
    }

    @Test("Rapid double barge: two dead turns, the third completes; exact event sequence")
    func rapidDoubleBarge() async {
        let bench = Bench(generator: .manual(replies: 3), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "one", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(9600)))   // barge 1
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })

            bench.transcripts.yield(.final("two", utterance: 1, at: Self.t(10560)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.audio.yield(.speechStarted(utterance: 2, at: Self.t(19200)))  // barge 2
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 1)) })

            bench.transcripts.yield(.final("three", utterance: 2, at: Self.t(20160)))
            #expect(await Self.until { bench.generator.repliesOpened == 3 })
            bench.generator.emit(reply: 2, token: "third")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 2)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 2)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .turnBarged(turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .turnBarged(turn: 1),
            .stateChanged(.listening, turn: 2),
            .stateChanged(.thinking, turn: 2),
            .replyToken("third", turn: 2),
            .stateChanged(.speaking, turn: 2),
            .turnCompleted(turn: 2),
            .stateChanged(.idle, turn: 2)
        ])
    }

    // MARK: - the input-side ticket (AC-62's second half)

    @Test("""
    A stale settled final never opens thinking; \
    a future final waits for its onset — identity decides, deterministically
    """)
    func staleSettledFinalIsNotAReplyTrigger() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Utterance 0 begins.
            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { await bench.coordinator.currentState == .listening })

            // Utterance 1's final arrives BEFORE its onset (cross-stream
            // reorder): identity says "future" — it must wait, not fire.
            bench.transcripts.yield(.final("current words", utterance: 1, at: Self.t(10560)))

            // Utterance 1's onset: the re-arm consumes the waiting final.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "the buffered CURRENT final must fire on its onset")
            #expect(bench.generator.record(ofReply: 0)?.transcript == "current words")

            // Utterance 0's settled final lands late (D-024): identity says
            // "stale" — dropped, deterministically, whatever the state.
            bench.transcripts.yield(.final("stale words", utterance: 0, at: Self.t(960)))

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 1,
                "the stale settled final must never reach the generator")
    }

    @Test("THE DESYNC REGRESSION (D-034): an onset this listener never saw cannot corrupt later turns")
    func missedOnsetHealsInsteadOfCorrupting() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Utterance 0's onset was DROPPED before reaching this
            // coordinator (bounded listener buffer, D-012) — it simply
            // never appears on the wire. Utterance 1 arrives normally.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96000)))
            #expect(await Self.until { await bench.coordinator.currentState == .listening })

            // The orphan's final arrives. Under the old mirror this looked
            // "from the future", waited, and answered utterance 2's onset —
            // every reply off by one, forever. Identity kills it instead.
            bench.transcripts.yield(.final("orphan words", utterance: 0, at: Self.t(960)))

            // The real utterance's final drives the turn with the RIGHT text.
            bench.transcripts.yield(.final("real words", utterance: 1, at: Self.t(97000)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 1)
        // AMENDED BY RULING (D-040 F-5, 2026-08-14). This once read
        // `== "real words"`. The claim D-034 makes — a lost onset costs
        // ONE utterance and cannot corrupt later turns — is about
        // TRIGGERING, and it is unchanged: still one reply, still driven
        // by utterance 1, still no off-by-one. What changed is content:
        // the orphan's WORDS are evidence the speaker really produced, so
        // they now join the thought while triggering nothing.
        #expect(bench.generator.record(ofReply: 0)?.transcript == "orphan words real words",
                "one lost onset must cost ONE utterance's TRIGGER, never every turn after it")
    }
}
