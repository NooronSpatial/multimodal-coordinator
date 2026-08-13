import Testing
import MultiModalKit
import MultiModalKitTesting
import Synchronization

/// RED SUITE for Phase 4a (SPEC §31–33, D-029..D-031): the turn loop.
///
/// The doctrine under test is the ticket, promoted one level: an utterance
/// ticket protected one decode; the TURN ticket must protect a chain —
/// generation feeding synthesis, both possibly mid-flight at the barge.
/// Defiant stages (ignore cancel, emit ghosts) carry the proof duty.
@Suite(.timeLimit(.minutes(1)))
struct TurnCoordinatorTests {

    static let sampleRate: Double = 48_000

    static func t(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: sampleRate)
    }

    /// Spin-capped gates — red fails fast, never hangs.
    @discardableResult
    static func until(_ condition: () async -> Bool, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    actor Collected {
        private(set) var events: [TurnEvent] = []
        func append(_ event: TurnEvent) { events.append(event) }
        func states() -> [TurnState] {
            events.compactMap { if case .stateChanged(let s, _) = $0 { s } else { nil } }
        }
    }

    /// Records every latency hand-off — exact values, not vibes.
    final class RecordingLatencyReporter: LatencyReporter, @unchecked Sendable {
        private let store = Mutex<([(Duration, Int)], [(Duration, Int)])>(([], []))
        var turnLatencies: [(Duration, Int)] { store.withLock { $0.0 } }
        var cancelLatencies: [(Duration, Int)] { store.withLock { $0.1 } }
        func turnLatency(_ duration: Duration, turn: Int) {
            store.withLock { $0.0.append((duration, turn)) }
        }
        func cancelLatency(_ duration: Duration, turn: Int) {
            store.withLock { $0.1.append((duration, turn)) }
        }
    }

    /// The whole loop on a bench: scripted stages, hand-driven input
    /// streams, a collector — and the coordinator in the middle.
    struct Bench<C: Clock> where C.Duration == Duration {
        let coordinator: TurnCoordinator<C>
        let generator: ScriptedReplyGenerator
        let synthesizer: ScriptedSynthesizer
        let audio: AsyncStream<AudioEvent>.Continuation
        let transcripts: AsyncStream<TranscriptEvent>.Continuation
        let box: Collected
        private let audioStream: AsyncStream<AudioEvent>
        private let transcriptStream: AsyncStream<TranscriptEvent>

        init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer)
        where C == ContinuousClock {
            var audioHandle: AsyncStream<AudioEvent>.Continuation!
            let audioStream = AsyncStream<AudioEvent> { audioHandle = $0 }
            var transcriptHandle: AsyncStream<TranscriptEvent>.Continuation!
            let transcriptStream = AsyncStream<TranscriptEvent> { transcriptHandle = $0 }
            self.init(
                generator: generator, synthesizer: synthesizer,
                coordinator: TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer),
                audioStream: audioStream, audio: audioHandle,
                transcriptStream: transcriptStream, transcripts: transcriptHandle)
        }

        /// The measuring bench (R2): manual clock in, exact durations out.
        init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer,
             clock: C, reporter: any LatencyReporter) {
            var audioHandle: AsyncStream<AudioEvent>.Continuation!
            let audioStream = AsyncStream<AudioEvent> { audioHandle = $0 }
            var transcriptHandle: AsyncStream<TranscriptEvent>.Continuation!
            let transcriptStream = AsyncStream<TranscriptEvent> { transcriptHandle = $0 }
            self.init(
                generator: generator, synthesizer: synthesizer,
                coordinator: TurnCoordinator(
                    replyGenerator: generator, synthesizer: synthesizer,
                    clock: clock, latencyReporter: reporter),
                audioStream: audioStream, audio: audioHandle,
                transcriptStream: transcriptStream, transcripts: transcriptHandle)
        }

        private init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer,
                     coordinator: TurnCoordinator<C>,
                     audioStream: AsyncStream<AudioEvent>,
                     audio: AsyncStream<AudioEvent>.Continuation,
                     transcriptStream: AsyncStream<TranscriptEvent>,
                     transcripts: AsyncStream<TranscriptEvent>.Continuation) {
            self.generator = generator
            self.synthesizer = synthesizer
            self.coordinator = coordinator
            self.audioStream = audioStream
            self.audio = audio
            self.transcriptStream = transcriptStream
            self.transcripts = transcripts
            self.box = Collected()
        }

        /// Runs the loop and the collector inside the given group.
        func start(in group: inout TaskGroup<Void>, listener: Broadcast<TurnEvent>.Listener) {
            let coordinator = coordinator
            let audioStream = audioStream
            let transcriptStream = transcriptStream
            let box = box
            group.addTask { await coordinator.run(audio: audioStream, transcripts: transcriptStream) }
            group.addTask { for await event in listener.events { await box.append(event) } }
        }

        /// One user utterance on the wire: onset, then its final.
        func speak(utterance: Int, final text: String, at frames: Int) {
            audio.yield(.speechStarted(at: Self.t(frames)))
            transcripts.yield(.final(text, utterance: utterance, at: Self.t(frames + 960)))
        }

        static func t(_ frames: Int) -> AudioTime { TurnCoordinatorTests.t(frames) }

        func finishInputs() {
            audio.finish()
            transcripts.finish()
        }
    }

    /// The AC-61 legal-transition table, test-side copy — the audit's ruler.
    static let legalPairs: [TurnState: Set<TurnState>] = [
        .idle: [.listening],
        .listening: [.thinking, .idle],
        .thinking: [.speaking, .listening, .idle],
        .speaking: [.listening, .idle],
    ]

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
            .stateChanged(.idle, turn: 0),
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
            bench.audio.yield(.speechStarted(at: Self.t(9600)))
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

        let events = await bench.box.events
        #expect(!events.contains(.replyToken("ghost", turn: 0)), "dead turn's token surfaced")
        #expect(!events.contains(.turnCompleted(turn: 0)), "dead turn completed")
        #expect(events.contains(.turnBarged(turn: 0)))
        #expect(events.contains(.turnCompleted(turn: 1)))
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
            bench.audio.yield(.speechStarted(at: Self.t(48000)))
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

        let events = await bench.box.events
        #expect(!events.contains(.replyToken("upon", turn: 0)))
        #expect(!events.contains(.turnCompleted(turn: 0)),
                "a dead turn's ghost 'finished' must not complete it")
        #expect(events.contains(.turnBarged(turn: 0)))
    }

    @Test("Rapid double barge: two dead turns, the third completes; exact event sequence")
    func rapidDoubleBarge() async {
        let bench = Bench(generator: .manual(replies: 3), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "one", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            bench.audio.yield(.speechStarted(at: Self.t(9600)))       // barge 1
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })

            bench.transcripts.yield(.final("two", utterance: 1, at: Self.t(10560)))
            #expect(await Self.until { bench.generator.repliesOpened == 2 })
            bench.audio.yield(.speechStarted(at: Self.t(19200)))      // barge 2
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
            .stateChanged(.idle, turn: 2),
        ])
    }

    // MARK: - the input-side ticket (AC-62's second half)

    @Test("A stale settled final from an earlier utterance never opens thinking")
    func staleSettledFinalIsNotAReplyTrigger() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Utterance 0 starts; the user pauses and restarts (utterance 1)
            // before any final: the session is settling utterance 0 (D-024).
            bench.audio.yield(.speechStarted(at: Self.t(0)))
            bench.audio.yield(.speechStarted(at: Self.t(9600)))
            #expect(await Self.until { await bench.coordinator.currentState == .listening })

            // Utterance 0's settled final lands LATE — mid-listening to 1.
            bench.transcripts.yield(.final("stale words", utterance: 0, at: Self.t(960)))

            // Then the CURRENT utterance's final arrives and drives the turn.
            bench.transcripts.yield(.final("current words", utterance: 1, at: Self.t(10560)))
            #expect(await Self.until { bench.generator.repliesOpened == 1 },
                    "exactly one reply — the current utterance's")

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 1)
        #expect(bench.generator.record(ofReply: 0)?.transcript == "current words",
                "the stale settled final must never reach the generator")
    }

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
            .stateChanged(.idle, turn: 0),
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

    @Test("A synthesizer failure mid-speech ends the turn; the reply run is cancelled")
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
            bench.audio.yield(.speechStarted(at: Self.t(144000)))
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

    // MARK: - stop() (AC-66)

    @Test("stop() mid-speaking: streams finish, both stage runs are cancelled, nothing publishes after")
    func stopMidSpeaking() async {
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))
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

            // A late report into the stopped loop must vanish.
            bench.synthesizer.reportFinished(utterance: 0)
            bench.finishInputs()
        }

        let events = await bench.box.events
        #expect(!events.contains(.turnCompleted(turn: 0)),
                "nothing may publish after stop()")
    }

    // MARK: - latency (R2: clock + injected reporter, exact under ManualClock)

    @Test("Turn latency = final accepted → the started evidence: exact on a manual clock")
    func turnLatencyExact() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter)
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "measure me", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // The user's wait: 250 ms of manual time before the mouth opens.
            await clock.advance(by: .milliseconds(250))
            bench.generator.emit(reply: 0, token: "tick")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(reporter.turnLatencies.count == 1)
        #expect(reporter.turnLatencies.first ?? (.zero, -1) == (.milliseconds(250), 0),
                "the felt pause must be EXACTLY the manual time that passed")
        #expect(reporter.cancelLatencies.isEmpty, "no barge happened — no cancel latency")
    }

    @Test("Cancel latency is exactly zero in mock time — teardown has no clock waits; a dead turn reports nothing")
    func cancelLatencyZeroInMockTime() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter)
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "doomed", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // Time passes while the turn thinks — it must NOT pollute the
            // cancel measurement, which starts at the barge itself.
            await clock.advance(by: .seconds(2))

            bench.audio.yield(.speechStarted(at: Self.t(96000)))   // the barge
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })
            #expect(await Self.until { !reporter.cancelLatencies.isEmpty })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(reporter.cancelLatencies.count == 1)
        #expect(reporter.cancelLatencies.first ?? (.seconds(9), -1) == (.zero, 0),
                "structural teardown takes no mock time — exactly zero, or a clock wait crept in")
        #expect(reporter.turnLatencies.isEmpty,
                "the turn died before speaking — a dead turn reports no turn latency")
    }
}
