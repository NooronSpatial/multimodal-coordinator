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
            events.compactMap { if case .stateChanged(let state, _) = $0 { state } else { nil } }
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
        .speaking: [.listening, .idle]
    ]
}

/// D-059 = A: a dead turn is a HEALTH event too — the road the mind's
/// tripwire alarm rides (D-058's promise, which the 4f review proved was
/// never built; the correction entry in DECISIONS.md tells that story).
/// Nil diagnostics stays byte-for-byte: every other test in this file
/// runs without one, which is that proof, free.
@Suite(.timeLimit(.minutes(1)))
struct TurnHealthTests {
    static func until(_ condition: () async -> Bool, within: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    actor HealthBox {
        private(set) var events: [HealthEvent] = []
        func append(_ event: HealthEvent) { events.append(event) }
    }

    @Test("a failed turn reaches the HEALTH stream, typed, with its turn number")
    func failedTurnReachesHealth() async {
        let diagnostics = PipelineDiagnostics()
        let generator = ScriptedReplyGenerator(plans: [.failOnOpen("no brain today")])
        let synthesizer = ScriptedSynthesizer(plans: [])
        let coordinator = TurnCoordinator(
            replyGenerator: generator, synthesizer: synthesizer,
            diagnostics: diagnostics)
        let turnListener = await coordinator.listen()
        let health = diagnostics.health()

        let collected = HealthBox()
        let audio = AsyncStream<AudioEvent>.makeStream()
        let transcripts = AsyncStream<TranscriptEvent>.makeStream()

        // Bound locals before the group, the bench's own pattern: a tuple
        // member captured inside a sending closure trips the race checker.
        let audioStream = audio.stream
        let transcriptStream = transcripts.stream
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await coordinator.run(audio: audioStream, transcripts: transcriptStream)
            }
            group.addTask {
                for await event in health.events { await collected.append(event) }
            }
            group.addTask { for await _ in turnListener.events {} }

            audio.continuation.yield(.speechStarted(utterance: 0, at: TurnCoordinatorTests.t(0)))
            transcripts.continuation.yield(.final("speak", utterance: 0, at: TurnCoordinatorTests.t(960)))

            #expect(await Self.until({
                await collected.events.contains {
                    if case .turnFailed(0, .generationFailed) = $0 { return true }
                    return false
                }
            }), "the coordinator's failure funnel must report to the health stream")

            audio.continuation.finish()
            transcripts.continuation.finish()
            await coordinator.stop()
            diagnostics.stop()
        }
    }
}
