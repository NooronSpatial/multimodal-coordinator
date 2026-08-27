import Foundation
import MultiModalKit
import MultiModalKitTesting
import Testing

/// THE BARGE WINDOW (4k, AC-156) — an onset must PERSIST before it may kill
/// a reply.
///
/// ## Why duration, and not level
///
/// Ten leaks and fifteen real utterances, measured across six field sessions
/// (INSTRUMENTS §43):
///
///     echo?    339 – 520 ms      peak 0.022 – 0.281
///     speech   939 – 3100 ms     peak 0.084 – 0.398
///
/// Duration separates them with a 419 ms gap. **Level does not** — the echo
/// reaches 0.281 and Ryad's own voice descends to 0.084. D-060 F-1 rejected
/// "raise the gate while speaking" for precisely that reason and is
/// confirmed, not overturned: every level-based cure was aimed at the wrong
/// axis. This one measures the other.
///
/// Ryad ruled 600 ms — 80 ms clear of the longest leak, 339 ms clear of the
/// shortest real utterance.
///
/// **Audio time, not a clock.** The field durations were measured on the
/// audio timeline, the events already carry it, and a test drives it
/// exactly. Nothing here needs a `Clock`.
@Suite("the barge window")
struct BargeWindowTests {

    /// Drives a turn to `.speaking`, delivers an onset and whatever followed
    /// it, and reports whether the speaking turn was barged.
    ///
    /// Built on `TurnCoordinatorTests.Bench` rather than a hand-rolled
    /// harness: the first version of this file spun its own and HUNG,
    /// because a `.manual` mouth never reports a terminal and `run` waited
    /// forever. The Bench gates on facts with a bounded `until`, which is
    /// the difference between a red test and a hung one.
    private func bargedAway(
        onsetFrames: Int,
        thenSegments: [Int],
        endedAt: Int?,
        trailingSegments: [Int] = [],
        window: Duration
    ) async -> Bool {
        let bench = TurnCoordinatorTests.Bench<ContinuousClock>(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true),
                                                      .manual()]),
            synthesizer: ScriptedSynthesizer(plans: [.manual(ignoresCancel: true),
                                                     .manual()]),
            config: .init(bargeWindow: window))
        let listener = await bench.coordinator.listen()
        var barged = false

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            // Get all the way to SPEAKING — the only state where the
            // assistant can hear itself.
            bench.speak(utterance: 0, final: "tell me a story", at: 0)
            _ = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            bench.generator.emit(reply: 0, token: "Once")
            _ = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            bench.synthesizer.reportStarted(utterance: 0)
            _ = await TurnCoordinatorTests.until {
                await bench.coordinator.currentState == .speaking
            }

            // The onset under test, and what followed it.
            bench.audio.yield(.speechStarted(utterance: 1,
                                             at: TurnCoordinatorTests.t(onsetFrames)))
            for frames in thenSegments {
                bench.audio.yield(.audioSegment(
                    AudioChunk(samples: [0], start: TurnCoordinatorTests.t(frames))))
            }
            if let endedAt {
                bench.audio.yield(.speechEnded(at: TurnCoordinatorTests.t(endedAt)))
            }
            for frames in trailingSegments {
                bench.audio.yield(.audioSegment(
                    AudioChunk(samples: [0], start: TurnCoordinatorTests.t(frames))))
            }

            // A barge moves the state to `.listening`. Bounded: if it never
            // happens this returns false rather than hanging.
            barged = await TurnCoordinatorTests.until({
                await bench.coordinator.currentState == .listening
            }, within: .seconds(2))

            bench.finishInputs()
            await bench.coordinator.stop()
        }
        return barged
    }

    /// 48 kHz: 1 ms = 48 frames.
    static func ms(_ milliseconds: Int) -> Int { milliseconds * 48 }

    // MARK: the two field shapes, from §43's own numbers

    @Test("a 480 ms burst — the echo's exact fingerprint — does NOT barge")
    func theEchoDoesNotBarge() async {
        // Config 4 of the ear test logged this twice, to the millisecond:
        // peak 0.043 · 480 ms, then peak 0.043 · 480 ms.
        let barged = await bargedAway(onsetFrames: Self.ms(1000),
                                      thenSegments: [Self.ms(1200), Self.ms(1400)],
                                      endedAt: Self.ms(1480),
                                      window: .milliseconds(600))
        #expect(!barged, "480 ms is the assistant hearing itself, not a person")
    }

    @Test("a 1160 ms utterance — the shortest real one ever logged — DOES barge")
    func realSpeechStillBarges() async {
        let barged = await bargedAway(
            onsetFrames: Self.ms(1000),
            thenSegments: [Self.ms(1200), Self.ms(1400), Self.ms(1700), Self.ms(2100)],
            endedAt: nil,
            window: .milliseconds(600))
        #expect(barged, "a person who keeps talking must still be able to interrupt")
    }

    /// FOUND BY MUTATION, not by design. Deleting the `.speechEnded` arm
    /// left every other test in this file green — so the arm was doing
    /// something nothing checked.
    ///
    /// What it does: a leak that ends must take its candidate with it.
    /// Otherwise the candidate stays armed, and the NEXT audio segment —
    /// which may belong to a completely different moment — sails past the
    /// stale deadline and barges instantly, with no window at all.
    @Test("a leak that ended cannot barge later on somebody else's audio")
    func endedCandidateDoesNotLingering() async {
        let barged = await bargedAway(
            onsetFrames: Self.ms(1000),
            thenSegments: [Self.ms(1200)],
            endedAt: Self.ms(1480),
            trailingSegments: [Self.ms(2000)],   // well past the old deadline
            window: .milliseconds(600))
        #expect(!barged, "the candidate died with the utterance that raised it")
    }

    // MARK: the edges of the ruled number

    @Test("just under the window does not barge")
    func justUnderDoesNotBarge() async {
        let barged = await bargedAway(onsetFrames: 0,
                                      thenSegments: [Self.ms(599)],
                                      endedAt: Self.ms(599),
                                      window: .milliseconds(600))
        #expect(!barged)
    }

    @Test("just over the window barges — it opens, it does not merely delay")
    func justOverBarges() async {
        let barged = await bargedAway(onsetFrames: 0,
                                      thenSegments: [Self.ms(601)],
                                      endedAt: nil,
                                      window: .milliseconds(600))
        #expect(barged)
    }

    @Test("zero window is the old behaviour — the first onset kills the reply")
    func zeroWindowBargesImmediately() async {
        let barged = await bargedAway(onsetFrames: 0,
                                      thenSegments: [],
                                      endedAt: nil,
                                      window: .zero)
        #expect(barged, "byte-for-byte 4a — and this is now the library DEFAULT")
    }

    /// THE TEST THAT FAILS IF THE WINDOW IS EVER WIDENED TOO FAR.
    ///
    /// The cost of this fix is a slower interruption, and the danger is that
    /// someone later "improves" it by widening the window until it swallows
    /// real speech — removing barge-in, the product's soul (D-060), while
    /// every other test here stays green.
    @Test("the measured window cannot swallow the shortest real utterance")
    func theWindowCannotSwallowSpeech() {
        let shortestRealUtterance = Duration.milliseconds(939)
        let longestLeak = Duration.milliseconds(520)
        // The MEASURED number, not the default — the default is zero,
        // because a library does not get to claim a policy (D-027).
        let window = BargeWindow.measured
        #expect(window < shortestRealUtterance)
        #expect(window > longestLeak)
    }
}
