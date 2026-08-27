import Testing
import Synchronization
import MultiModalKit
@testable import MultiModalKitTTS

/// 4o — AC-174. The run records one step per decode step, with what that
/// step COST and what it PRODUCED.
///
/// Time is injected (D-080's ruling A on the source fork): the run reads a
/// closure instead of `ContinuousClock().now`, so these wall times are
/// exact rather than whatever the machine felt like. No sleeps, no
/// tolerances — the banned pattern this suite exists to avoid.
/// A TIME LIMIT, because this suite drives a run whose stream only ends
/// when playback reports finished — and a spy host never does. A red test
/// here must fail fast rather than hang the whole run.
@Suite(.timeLimit(.minutes(1)))
struct DecodeStepRecordTests {

    static func until(_ condition: () async -> Bool,
                      within: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// A time source a test drives by hand. Each read advances by the
    /// scripted amount, so step N's cost is known before the test runs.
    final class ScriptedTime: Sendable {
        private let steps: Mutex<(instant: ContinuousClock.Instant, plan: [Duration])>

        init(_ plan: [Duration]) {
            self.steps = Mutex((ContinuousClock().now, plan))
        }

        /// The first read is the run's BIRTH and advances nothing; every
        /// later read advances by the next scripted duration.
        var now: @Sendable () -> ContinuousClock.Instant {
            // `self` captured, not the Mutex: a `Mutex` is non-copyable,
            // so a capture list would try to consume a stored property.
            { [self] in
                self.steps.withLock { state in
                    guard !state.plan.isEmpty else { return state.instant }
                    state.instant = state.instant.advanced(by: state.plan.removeFirst())
                    return state.instant
                }
            }
        }
    }

    @Test("one entry per step, carrying the audio that step produced")
    func oneEntryPerStep() async throws {
        // 24 kHz, so 2400 samples is exactly 100 ms — binary-exact, and
        // the reason the numbers below can be asserted with `==`.
        let decoder = ScriptedDecoder([.stepsProducing([2400, 4800, 1200])],
                                      sampleRate: 24_000)
        let host = SpyPlaybackHost()
        // birth, then three steps costing 50, 500 and 50 ms.
        let time = ScriptedTime([.zero, .milliseconds(50),
                                 .milliseconds(500), .milliseconds(50)])
        let run = try NeuralVoiceRun(decoder: decoder, host: host,
                                     lead: PlaybackLead(target: .zero),
                                     now: time.now)
        await run.feed("Three steps. ")   // the clause mark releases the phrase
        // GATED ON A FACT, not on a count or a sleep: the decoder itself
        // says how many steps it took. Draining `updates` instead would
        // hang, because this spy host never reports playback finished —
        // which is the strand D-055 documents, not this test's subject.
        #expect(await Self.until { decoder.stepsTaken == 3 })
        await run.cancel()

        let steps = run.stepTotals.withLock { $0.steps }
        #expect(steps.count == 3)
        #expect(steps.map(\.audioMilliseconds) == [100, 200, 50])
        #expect(steps.map(\.wallMilliseconds) == [50, 500, 50])
    }

    /// THE WHOLE POINT, END TO END — and the first draft of this test was
    /// WRONG in a way worth keeping in the record: it used a decode where
    /// both rules happen to agree (250 ms each), and proved nothing. The
    /// two only diverge when the deficit PEAKS and is then repaid.
    ///
    /// Here: a step that costs 500 ms and produces nothing, then a step
    /// that produces 900 ms of audio in 100 ms. The bank had to be 500 ms
    /// deep to survive the stall — but by the end the decoder is AHEAD,
    /// so the old rule (`wall − audio` = 600 − 900) asks for nothing at
    /// all, and the sentence breaks.
    @Test("the record finds a peak the old rule reads as zero")
    func theRecordFindsThePeakTheOldRuleMisses() async throws {
        // 21600 samples at 24 kHz is exactly 900 ms.
        let decoder = ScriptedDecoder([.stepsProducing([0, 21600])],
                                      sampleRate: 24_000)
        let host = SpyPlaybackHost()
        let time = ScriptedTime([.zero, .milliseconds(500), .milliseconds(100)])
        let run = try NeuralVoiceRun(decoder: decoder, host: host,
                                     lead: PlaybackLead(target: .zero),
                                     now: time.now)
        await run.feed("Stall then flood. ")
        #expect(await Self.until { decoder.stepsTaken == 2 })
        await run.cancel()

        let steps = run.stepTotals.withLock { $0.steps }
        #expect(steps.map(\.wallMilliseconds) == [500, 100])
        #expect(steps.map(\.audioMilliseconds) == [0, 900])

        // The new rule banks the peak.
        #expect(DecodeDeficit.worstLag(steps: steps) == 500)

        // The old rule, written as the algebra it really is:
        //   audio × (RTF − 1)  ==  wall − audio
        // It asks for NOTHING here, on a decode that starved for half a
        // second. This is D-080's ruling in two lines.
        let audio = steps.reduce(0.0) { $0 + $1.audioMilliseconds }
        let wall = steps.reduce(0.0) { $0 + $1.wallMilliseconds }
        #expect(max(0, wall - audio) == 0)
    }

    @Test("a decode that produces nothing records nothing to size from")
    func noStepsNoRecord() async throws {
        let decoder = ScriptedDecoder([.throwsAtOnce("nothing decoded")])
        let host = SpyPlaybackHost()
        let run = try NeuralVoiceRun(decoder: decoder, host: host,
                                     lead: PlaybackLead(target: .zero))
        await run.feed("Dead on arrival. ")
        #expect(await Self.until { decoder.threw })
        await run.cancel()
        #expect(run.stepTotals.withLock { $0.steps }.isEmpty)
        #expect(DecodeDeficit.worstLag(steps: run.stepTotals.withLock { $0.steps }) == 0)
    }
}
