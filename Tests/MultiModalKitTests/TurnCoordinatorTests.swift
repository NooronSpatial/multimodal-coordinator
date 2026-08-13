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
        /// `config` carries the reply gate for the AC-81 tests.
        init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer,
             clock: C, reporter: any LatencyReporter,
             config: TurnCoordinator<C>.Config = .init()) {
            var audioHandle: AsyncStream<AudioEvent>.Continuation!
            let audioStream = AsyncStream<AudioEvent> { audioHandle = $0 }
            var transcriptHandle: AsyncStream<TranscriptEvent>.Continuation!
            let transcriptStream = AsyncStream<TranscriptEvent> { transcriptHandle = $0 }
            self.init(
                generator: generator, synthesizer: synthesizer,
                coordinator: TurnCoordinator(
                    replyGenerator: generator, synthesizer: synthesizer, config: config,
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
            audio.yield(.speechStarted(utterance: utterance, at: Self.t(frames)))
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
            .stateChanged(.idle, turn: 1),
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
            .stateChanged(.idle, turn: 1),
        ])
    }

    @Test("Barge-in MID-GENERATION: tokens flowing, mouth open but still silent — both runs die; a ghost 'started' cannot flip the new turn")
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
            .stateChanged(.idle, turn: 1),
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
            .stateChanged(.idle, turn: 2),
        ])
    }

    // MARK: - the input-side ticket (AC-62's second half)

    @Test("A stale settled final never opens thinking; a future final waits for its onset — identity decides, deterministically")
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
        #expect(bench.generator.record(ofReply: 0)?.transcript == "real words",
                "one lost onset must cost ONE utterance, never every turn after it")
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

    @Test("The synthesizer refuses to open: turnFailed with the reason, the reply run is cancelled, the next turn runs clean")
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

    @Test("A final arriving BEFORE its own speechStarted waits, then drives the turn; a duplicate final is dropped at the door")
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
            .stateChanged(.idle, turn: 0),
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

    @Test("Lifecycle negative space: a second run() returns at once; stop() is idempotent; after stop the state is idle and listeners finish immediately")
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

    // MARK: - the reply gate (AC-81, D-037 F-3: mechanism here, number with the app)

    /// A bounded "nothing happened" check: give the loop room to betray
    /// itself, then assert it did not. The positive twin of `until`.
    static func settled(spins: Int = 2_000) async {
        for _ in 0..<spins { await Task.yield() }
    }

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
            // Event-gate: the gate is ARMED (its sleeper is parked on the
            // clock) before any time moves — advancing first would let the
            // deadline be computed from already-advanced time.
            #expect(await Self.until { clock.sleeperCount == 1 }, "the gate never armed")
            // 499 of 500 ms: the gate must still hold — no thinking, no
            // generator, state parked on listening.
            await clock.advance(by: .milliseconds(499))
            await Self.settled()
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
            #expect(await Self.until { clock.sleeperCount == 1 }, "the gate never armed")
            await clock.advance(by: .milliseconds(200))
            // The user resumes: same turn keeps listening, the pending
            // reply dies with NO events — no thinking, no ghost turn.
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
            await clock.advance(by: .seconds(10))         // the dead gate expires into nothing
            await Self.settled()
            #expect(bench.generator.repliesOpened == 0, "a killed gate still opened the generator")
            #expect(await bench.coordinator.currentState == .listening)

            // The user's REAL final gates again and goes through.
            bench.transcripts.yield(.final("now I am done", utterance: 1, at: Self.t(96_000)))
            #expect(await Self.until { clock.sleeperCount == 1 }, "the second gate never armed")
            await clock.advance(by: .milliseconds(500))
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            #expect(bench.generator.record(ofReply: 0)?.transcript == "now I am done",
                    "the generator must open with the SECOND final's text")

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
            #expect(await Self.until { clock.sleeperCount == 1 }, "the gate never armed")
            await clock.advance(by: .milliseconds(499))
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(24_000)))
            // The onset must be IN before the last tick fires the gate.
            #expect(await Self.until { await bench.coordinator.currentUtterance == 1 },
                    "the onset was not processed before the deciding tick")
            await clock.advance(by: .milliseconds(1))
            await Self.settled()
            #expect(bench.generator.repliesOpened == 0, "the onset lost a race it arrived first for")
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
            #expect(await Self.until { clock.sleeperCount == 1 }, "the gate never armed")
            await clock.advance(by: .milliseconds(100))
            // A settled final from an EARLIER utterance (D-024): the input
            // door drops it — it must not disturb the armed gate.
            bench.transcripts.yield(.final("stale comfort text", utterance: 3, at: Self.t(10)))
            await Self.settled()
            await clock.advance(by: .milliseconds(400))   // the gate completes
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            #expect(bench.generator.record(ofReply: 0)?.transcript == "armed",
                    "the stale final must neither open nor replace the armed reply")

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
            #expect(await Self.until { clock.sleeperCount == 1 },
                    "the gate must be PROVABLY armed before stop() — else the leak check is vacuous")
            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(bench.generator.repliesOpened == 0)
        #expect(clock.sleeperCount == 0, "the gate's sleeper survived stop()")
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

            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96000)))   // the barge
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
