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

    /// A bounded "nothing happened" check: give the loop room to betray
    /// itself, then assert it did not. The positive twin of `until`.
    static func settled(spins: Int = 2_000) async {
        for _ in 0..<spins { await Task.yield() }
    }

    /// Gates on a FACT, with a deadline as the backstop — red still fails
    /// fast and can never hang.
    ///
    /// It was a spin COUNT until the 4d review's fixes landed, and a
    /// 20-round stability sweep then reported ten failures that ~50
    /// subsequent rounds could not reproduce — including six under
    /// deliberate CPU load. The cause was never identified and is
    /// recorded as unexplained. What a count DOES do, provably, is tie
    /// the budget to scheduler behaviour rather than to elapsed time, so
    /// a busy machine can exhaust it before a perfectly correct pipeline
    /// answers. Removing that coupling costs nothing and removes a whole
    /// class of doubt from every future sweep.
    @discardableResult
    static func until(_ condition: () async -> Bool, within: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// Waits for the FACT that something is parked on the clock — the house
    /// pattern from `AudioPumpTests.parked`. The clock also offers an
    /// event-driven `waitForSleepers`, which is prettier but parks forever
    /// when the sleeper never comes; this polls the same fact with a spin
    /// cap, so a red test dies in milliseconds instead of at the suite's
    /// one-minute limit. Fact-gated AND fail-fast: both laws, not one.
    @discardableResult
    static func parked(_ clock: ManualClock, atLeast count: Int = 1, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if clock.sleeperCount >= count { return true }
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

        init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer,
             config: TurnCoordinator<ContinuousClock>.Config = .init())
        where C == ContinuousClock {
            var audioHandle: AsyncStream<AudioEvent>.Continuation!
            let audioStream = AsyncStream<AudioEvent> { audioHandle = $0 }
            var transcriptHandle: AsyncStream<TranscriptEvent>.Continuation!
            let transcriptStream = AsyncStream<TranscriptEvent> { transcriptHandle = $0 }
            self.init(
                generator: generator, synthesizer: synthesizer,
                coordinator: TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer,
                                             config: config),
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

        /// The raw streams, for the rare test that must drive `run()`
        /// itself rather than let `start` do it.
        var audioEvents: AsyncStream<AudioEvent> { audioStream }
        var transcriptEvents: AsyncStream<TranscriptEvent> { transcriptStream }

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

    @Test("A barge carries the interrupted thought forward (AC-89, F-3 = A, provisional)")
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

        #expect(bench.generator.record(ofReply: 1)?.transcript
                == "the interrupted thought and the rest of it",
                "the barged reply never landed, so its words were never answered")
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
