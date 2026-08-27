// `TurnCoordinatorTests`, continued: stop(), the reorder buffer and the
// input door, and the loop's lifecycle.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - stop() (AC-66)

    @Test("stop() mid-speaking: streams finish, both stage runs are cancelled, nothing publishes after")
    func stopMidSpeaking() async {
        // The synthesizer is DEFIANT so the post-stop report really enters
        // the machinery instead of dying inside a polite mock — the same
        // vacuity the house was burned by twice (review finding).
        let bench = Bench(
            generator: .manual(replies: 1),
            synthesizer: ScriptedSynthesizer(plans: [.manual(ignoresCancel: true)]))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "unfinished", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "half")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            await bench.coordinator.stop()
            #expect(await Self.until { bench.generator.record(ofReply: 0)?.cancelled == true })
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.cancelled == true })

            // A late report into the stopped loop must vanish — FORCED
            // past the mock's manners, so it really reaches the merge.
            bench.synthesizer.forceUpdate(utterance: 0, .finished)
            bench.finishInputs()
        }

        let events = await bench.box.events
        #expect(!events.contains(.turnCompleted(turn: 0)),
                "nothing may publish after stop()")
    }

    @Test("A reply that fails MID-STREAM while speaking: turnFailed, the mouth is cancelled, the next turn runs clean")
    func replyFailsMidStreamCancelsTheMouth() async {
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "tell me more", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "well")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            // The generator dies mid-sentence, mid-SPEECH.
            bench.generator.fail(reply: 0, reason: "brain died")
            #expect(await Self.until { await bench.box.events.contains(
                .turnFailed(.generationFailed("brain died"), turn: 0)) })
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.cancelled == true },
                    "a dead reply must silence the mouth it was feeding")

            // The next turn is untouched.
            bench.speak(utterance: 1, final: "again", at: 96000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "fresh")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 2 })
            bench.synthesizer.reportStarted(utterance: 1)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 1)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 1)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.coordinator.currentState == .idle)
    }

    @Test("""
    The synthesizer refuses to open: turnFailed with the reason, \
    the reply run is cancelled, the next turn runs clean
    """)
    func synthesizerRefusesToOpen() async {
        let bench = Bench(
            generator: .manual(replies: 2),
            synthesizer: ScriptedSynthesizer(plans: [.failOnOpen("no voice"), .manual()]))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "speak", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "first")   // opens the mouth: it throws
            #expect(await Self.until { await bench.box.events.contains(
                .turnFailed(.synthesisFailed("no voice"), turn: 0)) },
                    "the open-failure must surface with its reason intact")
            #expect(await Self.until { bench.generator.record(ofReply: 0)?.cancelled == true },
                    "a turn whose mouth never opened must not keep generating")

            bench.speak(utterance: 1, final: "retry", at: 96000)
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.generator.emit(reply: 1, token: "ok")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 2 })
            bench.synthesizer.reportStarted(utterance: 1)
            bench.generator.finish(reply: 1)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 1)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 1)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(await bench.coordinator.currentState == .idle)
    }

    @Test("The user's utterance itself fails to become text: the turn ends as transcriptionFailed, the loop lives on")
    func transcriptionFailureEndsTheTurn() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            bench.transcripts.yield(.failed(.engineFailed("mic route died"),
                                            utterance: 0, at: Self.t(960)))
            #expect(await Self.until { await bench.box.events.contains(
                .turnFailed(.transcriptionFailed(.engineFailed("mic route died")), turn: 0)) })

            // The next utterance transcribes fine; its turn runs clean.
            bench.speak(utterance: 1, final: "hello again", at: 96000)
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "only the healthy utterance may reach the generator")
            bench.generator.emit(reply: 0, token: "hi")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 1)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.record(ofReply: 0)?.transcript == "hello again")
        #expect(await bench.box.events.contains(.stateChanged(.idle, turn: 0)))
    }

    // MARK: - the reorder buffer and the input door (review findings)

    @Test("""
    A final arriving BEFORE its own speechStarted waits, then drives the turn; \
    a duplicate final is dropped at the door
    """)
    func earlyFinalWaitsForItsOnset() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Cross-stream reorder, forced deterministically: the final is
            // on the wire before anyone has spoken.
            bench.transcripts.yield(.final("early words", utterance: 0, at: Self.t(960)))
            bench.audio.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "the buffered final must fire the moment its utterance is born")
            #expect(bench.generator.record(ofReply: 0)?.transcript == "early words")

            // The SAME final again — the door must drop it (not listening).
            bench.transcripts.yield(.final("early words", utterance: 0, at: Self.t(960)))

            bench.generator.emit(reply: 0, token: "ok")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 1, "the duplicate final must never open a second reply")
        #expect(await bench.box.events == [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("ok", turn: 0),
            .stateChanged(.speaking, turn: 0),
            .turnCompleted(turn: 0),
            .stateChanged(.idle, turn: 0)
        ], "exactly one turn, exactly one thinking — order restored, duplicate dropped")
    }

    @Test("A defiant token AFTER the reply finished is dropped: not published, not fed to the mouth")
    func postFinishTokenIsDropped() async {
        let bench = Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true)]),
            synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "brief", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "a")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            // The reply ends — forced, so the defiant stream STAYS OPEN.
            bench.generator.forceFinished(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })

            // The sentence is over; a late defiant token must be noise.
            bench.generator.forceToken(reply: 0, token: "late")

            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(!(await bench.box.events.contains(.replyToken("late", turn: 0))),
                "a post-finish token surfaced")
        #expect(bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["a"],
                "a post-finish token was fed to the mouth")
    }

    // MARK: - lifecycle (review findings: the negative space)

    @Test("Input exhaustion ends the loop gracefully: run() returns and listeners finish, no stop() needed")
    func gracefulEndOnInputExhaustion() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "the end", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.generator.emit(reply: 0, token: "bye")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            // No stop(). The inputs simply end — and the whole group must
            // drain: run() returns, the broadcast finishes, the collector's
            // stream ends. If any of that fails, this test TIMES OUT.
            bench.finishInputs()
        }

        #expect(await bench.box.events.last == .stateChanged(.idle, turn: 0))
    }

    @Test("""
    Lifecycle negative space: a second run() returns at once; \
    stop() is idempotent; after stop the state is idle and listeners finish immediately
    """)
    func lifecycleNegativeSpace() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "   ", at: 0)   // blank → idle
            #expect(await Self.until { await bench.box.events.contains(.stateChanged(.idle, turn: 0)) })

            // A second run() while the first is live: returns immediately.
            var audioHandle: AsyncStream<AudioEvent>.Continuation!
            let secondAudio = AsyncStream<AudioEvent> { audioHandle = $0 }
            audioHandle.finish()
            var transcriptHandle: AsyncStream<TranscriptEvent>.Continuation!
            let secondTranscripts = AsyncStream<TranscriptEvent> { transcriptHandle = $0 }
            transcriptHandle.finish()
            await bench.coordinator.run(audio: secondAudio, transcripts: secondTranscripts)

            await bench.coordinator.stop()
            await bench.coordinator.stop()   // idempotent — no crash, no effect
            bench.finishInputs()
        }

        #expect(await bench.coordinator.currentState == .idle)
        // A listener taken AFTER stop: its stream is already finished.
        let late = await bench.coordinator.listen()
        var lateEvents: [TurnEvent] = []
        for await event in late.events { lateEvents.append(event) }
        #expect(lateEvents.isEmpty, "a post-stop listener must get an immediately-finished stream")
    }
}
