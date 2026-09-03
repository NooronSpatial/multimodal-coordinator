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
@Suite(.timeLimit(.minutes(1)), .serialized)
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
        // A REAL host, and that is not incidental. `SpyPlaybackHost`
        // records attachments without joining a graph, so the run's
        // player node has no output format — scheduling actual samples on
        // it throws an NSException that kills the whole test process.
        // Every earlier test escaped that only because `.steps(n)`
        // produces EMPTY samples, which `render` skips. This suite is the
        // first to push real audio through, so it renders on a real
        // engine and skips honestly where there is none (the D-022 rule).
        let host = AudioEnginePlaybackHost()
        defer { host.stopRendering() }
        let time = ScriptedTime([.zero, .milliseconds(50),
                                 .milliseconds(500), .milliseconds(50)])
        guard let run = try? NeuralVoiceRun(decoder: decoder, host: host,
                                            lead: PlaybackLead(target: .zero),
                                            now: time.now) else { return }
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

    /// THE FIRST STEP'S AUDIO REACHES THE MARGIN (4q, D-085).
    ///
    /// The run has always counted the first step's samples and never
    /// reported them, so a phone showed "prefill 632 ms" with no way to
    /// read it — warm for a 2.5-second phrase, cold for a 1-second one.
    /// This pins that the number now travels: 2400 samples at 24 kHz is
    /// exactly 100 ms, and the prefill beside it is the scripted 50 ms.
    ///
    /// Gated on the margin ARRIVING, with the house cap, rather than on a
    /// drain: a margin is reported at the reply's terminal, and on this
    /// real host the 350 ms of audio plays out and `finished` fires. On a
    /// runner with no output the host refuses at construction and the
    /// test skips honestly above, as the sibling test does.
    @Test("the margin carries the first step's audio beside its wall time")
    func marginCarriesFirstStepAudio() async throws {
        let decoder = ScriptedDecoder([.stepsProducing([2400, 4800, 1200])],
                                      sampleRate: 24_000)
        let host = AudioEnginePlaybackHost()
        defer { host.stopRendering() }
        let time = ScriptedTime([.zero, .milliseconds(50),
                                 .milliseconds(500), .milliseconds(50)])
        let captured = Mutex<DecodeMargin?>(nil)
        guard let run = try? NeuralVoiceRun(decoder: decoder, host: host,
                                            lead: PlaybackLead(target: .zero),
                                            onMargin: { margin in captured.withLock { $0 = margin } },
                                            now: time.now) else { return }
        await run.feed("Three steps. ")
        await run.finishTokens()

        #expect(await Self.until { captured.withLock { $0 } != nil },
                "the terminal must report a margin — a reply that never finishes has none")
        let margin = captured.withLock { $0 }
        #expect(margin?.firstStepAudioMilliseconds == 100,
                "2400 samples at 24 kHz, multiplied before divided")
        // ROUNDED, not `==`, and the reason is worth keeping: `prefill` is
        // the run's own `ms()` helper — `attoseconds × 1e-15` — and 1e-15
        // has no exact binary form, so the scripted 50 ms arrives as
        // 50.00000000000001. That is a property of the existing field, not
        // of this change; the NEW field above multiplies before dividing
        // and is asserted exactly, which is the whole point of that order.
        #expect(margin?.prefillMilliseconds.rounded() == 50,
                "birth to the first step, as scripted")
        #expect(margin?.audioMilliseconds == 350)
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
        let host = AudioEnginePlaybackHost()
        defer { host.stopRendering() }
        let time = ScriptedTime([.zero, .milliseconds(500), .milliseconds(100)])
        guard let run = try? NeuralVoiceRun(decoder: decoder, host: host,
                                            lead: PlaybackLead(target: .zero),
                                            now: time.now) else { return }
        await run.feed("Stall then flood. ")
        #expect(await Self.until { decoder.stepsTaken == 2 })
        await run.cancel()

        let steps = run.stepTotals.withLock { $0.steps }
        #expect(steps.map(\.wallMilliseconds) == [500, 100])
        #expect(steps.map(\.audioMilliseconds) == [0, 900])

        // The corrected model: playback must not start before wall 500
        // (nothing had arrived by then), and the cushion is the audio
        // that exists at the first buffer boundary at or after it — the
        // 900 ms that step 2 delivers. The pre-playback wait is NOT
        // banked; it only delays the start.
        // 600, not 500: at wall 600 the second step's time is spent and
        // its 900 ms of audio has not arrived yet.
        #expect(DecodeDeficit.requiredStart(steps: steps) == 600)
        #expect(DecodeDeficit.cushion(steps: steps) == 900)

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
        #expect(DecodeDeficit.cushion(steps: run.stepTotals.withLock { $0.steps }) == 0)
    }
}
