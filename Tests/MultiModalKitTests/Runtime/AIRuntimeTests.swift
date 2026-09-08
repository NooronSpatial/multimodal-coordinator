import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

/// THE FRONT DOOR'S THREE RULES, PROVEN (4t, D-093, AC-202..AC-204).
///
/// Each rule below was a COMMENT in an application before this type
/// existed. A comment is not a mechanism: the first-utterance rule was
/// obeyed by both demos and enforced by nothing, and the teardown order
/// was missing from one demo entirely. These tests are what could not be
/// written before, which is the milestone's own evidence it earned its
/// place.
///
/// **Nothing here polls.** The first version waited with a spin of
/// `Task.yield()` — first capped by a COUNT (§3.3 forbids it in those
/// words), then by a deadline. Both are polls. On the CI runner, whose
/// cooperative pool is a few threads wide, three concurrent spinners made
/// every other test crawl at ~2.2 s and the process then froze for six
/// hours. So every wait is now an EVENT — an `AsyncStream` the observer
/// signals into — raced against a SLEEPING deadline, which is a
/// suspension and not a spin. A red test still dies in ten seconds.
///
/// `.serialized`: each test stands up and cancels a whole `AIRuntime` task
/// tree. Four of those overlapping is the one thing 4t added to the test
/// process, and until the runner's freeze is explained they do not overlap.
/// Cost: milliseconds.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct AIRuntimeTests {

    /// Records the ORDER things happened in, from any task. Read only
    /// AFTER the runtime has returned — never waited on.
    final class Recorder: Sendable {
        private let events = Mutex<[String]>([])
        func note(_ event: String) { events.withLock { $0.append(event) } }
        var log: [String] { events.withLock { $0 } }
    }

    /// The EVENT a test waits on (§3.3: gate on facts, never on delays or
    /// counts). The observer `send`s a name; the test awaits that name,
    /// racing a sleeping deadline. One wait per instance — an
    /// `AsyncStream` has one consumer.
    final class Signals: Sendable {
        private let stream: AsyncStream<String>
        private let emit: AsyncStream<String>.Continuation
        init() {
            (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        }
        func send(_ name: String) { emit.yield(name) }
        /// True when `name` arrives before the deadline. The loser of the
        /// race is cancelled, never abandoned.
        func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { [stream] in
                    for await event in stream where event == name { return true }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: deadline)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }
    }

    static func configuration(
        recorder: Recorder,
        mind: (any ReplyGenerating)? = nil,
        mouth: (any SpeechSynthesizing)? = nil,
        diagnostics: PipelineDiagnostics? = nil
    ) -> AIRuntime<ManualClock>.Configuration {
        let (_, consumer) = AudioRing.create(minimumCapacity: 4_096)
        return .init(
            consumer: consumer,
            vad: EnergyVAD(config: .init(threshold: 0.25, hangoverFrames: 4)),
            ear: ScriptedTranscriber(plans: [.normal(partialEveryChunks: 1)]),
            mind: mind, mouth: mouth,
            pump: .init(sampleRate: 16_000, pollInterval: .milliseconds(10),
                        chunkFrames: 320, preRollChunks: 2),
            transcription: .init(format: .init(sampleRate: 16_000, channels: 1)),
            turns: .init(),
            clock: ManualClock(),
            diagnostics: diagnostics,
            stopRendering: { recorder.note("stopRendering") },
            releaseSource: { recorder.note("releaseSource") })
    }

    // MARK: - AC-202: listeners before loops

    /// **THE FIRST EVENT IS NEVER LOST.** `PipelineDiagnostics.run()`
    /// publishes the current thermal state as its very first act — so if
    /// the runtime started that loop BEFORE opening the app's health
    /// listener, the event would be gone before anyone could hear it.
    /// This is the first-utterance rule, probed with the one event whose
    /// timing is exact rather than clock-driven.
    @Test("the app's listeners are open before any loop publishes (AC-202)")
    func listenersAreOpenBeforeLoopsRun() async {
        let recorder = Recorder()
        let signals = Signals()
        let runtime = AIRuntime(Self.configuration(
            recorder: recorder, diagnostics: PipelineDiagnostics()))

        let task = Task {
            await runtime.run { session in
                guard let health = session.health else { return }
                for await event in health.events {
                    if case .thermal = event { signals.send("thermal"); return }
                }
            }
        }
        #expect(await signals.heard("thermal"),
                "the initial thermal event was published before the listener existed")
        task.cancel()
        await task.value
    }

    // MARK: - AC-203: the teardown order

    /// **THE THREE STEPS, IN ORDER, PROVEN.** The turns stream ending is
    /// the evidence the coordinator was stopped (its `stop()` finishes the
    /// broadcast) — that is step 1. Step 2 and step 3 are the app's own
    /// closures, recorded as they are called. The order is the milestone.
    @Test("teardown runs actors → stopRendering → releaseSource (AC-203)")
    func teardownRunsInOrder() async {
        let recorder = Recorder()
        let signals = Signals()
        let runtime = AIRuntime(Self.configuration(
            recorder: recorder,
            mind: ScriptedReplyGenerator.manual(replies: 1),
            mouth: ScriptedSynthesizer.manual(utterances: 1)))

        let task = Task {
            await runtime.run { session in
                guard let turns = session.turns else {
                    recorder.note("NO TURNS LISTENER"); return
                }
                recorder.note("observing")
                signals.send("observing")
                for await _ in turns.events {}
                recorder.note("turns ended")     // the coordinator was stopped
            }
        }
        #expect(await signals.heard("observing"))
        task.cancel()
        await task.value

        let log = recorder.log
        #expect(log.contains("turns ended"), "the coordinator must be stopped on the way out")
        #expect(log.contains("stopRendering"), "step 2 must run")
        #expect(log.contains("releaseSource"), "step 3 must run")
        let order = ["turns ended", "stopRendering", "releaseSource"].compactMap { log.firstIndex(of: $0) }
        #expect(order == order.sorted() && order.count == 3,
                "the order is the fix: \(log)")
    }

    /// Listen-only (F-3 = B): no mind, no mouth, no turns listener — and
    /// the teardown still runs, still in order, with step 2 absent.
    @Test("listen-only tears down source-last with no rendering step")
    func listenOnlyTearsDown() async {
        let recorder = Recorder()
        let signals = Signals()
        var config = Self.configuration(recorder: recorder)
        config.stopRendering = nil
        let runtime = AIRuntime(config)

        let task = Task {
            await runtime.run { session in
                #expect(session.turns == nil, "no mind, no mouth, no turns")
                recorder.note("observing")
                signals.send("observing")
                for await _ in session.transcripts.events {}
                recorder.note("transcripts ended")
            }
        }
        #expect(await signals.heard("observing"))
        task.cancel()
        await task.value

        let log = recorder.log
        #expect(log.last == "releaseSource", "the source is released LAST: \(log)")
        #expect(!log.contains("stopRendering"))
    }

    // MARK: - AC-204: no policy of its own

    /// The runtime passes the app's config types through UNTOUCHED. The
    /// values here are deliberately odd so a normalising runtime would
    /// show. The compile-time half of this criterion is in the initializer:
    /// `pump`, `transcription` and `turns` have no default there, and a
    /// test that had to supply them is the proof.
    @Test("every policy value goes through untouched (AC-204)")
    func policyPassesThroughUntouched() {
        let (_, consumer) = AudioRing.create(minimumCapacity: 1_024)
        let config = AIRuntime<ManualClock>.Configuration(
            consumer: consumer,
            vad: EnergyVAD(config: .init(threshold: 0.125, hangoverFrames: 3)),
            ear: ScriptedTranscriber(plans: []),
            pump: .init(sampleRate: 22_050, pollInterval: .milliseconds(7),
                        chunkFrames: 441, preRollChunks: 9),
            transcription: .init(maximumUtterance: .seconds(11)),
            turns: .init(replyGate: .milliseconds(123), maxContextPieces: 5,
                         bargeWindow: .milliseconds(456),
                         maxMemoryTurns: 3, maxMemoryCharacters: 321),
            clock: ManualClock(),
            releaseSource: {})
        let runtime = AIRuntime(config)

        #expect(runtime.configuration.pump.sampleRate == 22_050)
        #expect(runtime.configuration.pump.preRollChunks == 9)
        #expect(runtime.configuration.transcription.maximumUtterance == .seconds(11))
        #expect(runtime.configuration.turns.replyGate == .milliseconds(123))
        #expect(runtime.configuration.turns.bargeWindow == .milliseconds(456))
        #expect(runtime.configuration.turns.maxMemoryCharacters == 321,
                "D-092's bound is the app's to set; the door must not re-decide it")
    }
}
