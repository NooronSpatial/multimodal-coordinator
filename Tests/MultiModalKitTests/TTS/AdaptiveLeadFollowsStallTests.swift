import Testing
import MultiModalKit
@testable import MultiModalKitTTS

/// 4o — AC-176. The cushion follows the WORST STALL, not the mean rate
/// (D-080).
///
/// The suite is written as the RED proof first: every expectation here
/// fails against `replyLength × (steadyRealTimeFactor − 1)`, and the
/// commit that turns it green is the one that retires that rule.
@Suite("the cushion follows the stall")
struct AdaptiveLeadFollowsStallTests {

    /// A margin whose whole-run numbers say one thing and whose step
    /// record says another — which is the entire subject.
    static func margin(audio: Double, wall: Double, worstLag: Double) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: audio,
                     wallMilliseconds: wall,
                     prefillMilliseconds: 0,
                     steadyRealTimeFactor: wall / audio,
                     completed: true,
                     cushionMilliseconds: 0,
                     worstLagMilliseconds: worstLag)
    }

    /// THE CASE §53 MEASURED AND THE OLD RULE CALLED "SAFE".
    ///
    /// A decode that stalls for 500 ms and then catches up: by the end it
    /// is AHEAD, so `audio × (RTF − 1)` is negative and asks for nothing.
    /// The bank still had to be 500 ms deep or the sentence broke.
    @Test("a stall repaid by the end still sizes the cushion")
    func stallRepaidStillSizes() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(audio: 900, wall: 600, worstLag: 500))
        #expect(adaptive.target == .milliseconds(500))

        // What the retired rule would have asked for, stated in the test
        // so the gap is visible: nothing at all.
        #expect(max(0, 600 - 900) == 0)
    }

    /// The old rule's own good case must keep working: when the decode is
    /// uniformly slow, the running maximum IS the endpoint, and both
    /// rules agree. This is the test that says uniformity was the false
    /// assumption rather than the arithmetic.
    @Test("a uniformly slow decode sizes the same as it always did")
    func uniformlySlowIsUnchanged() {
        let adaptive = AdaptiveLead()
        // 2000 ms of audio in 2500 ms: 500 ms behind at the end, and the
        // running maximum of a steady climb is that same 500.
        adaptive.observe(Self.margin(audio: 2000, wall: 2500, worstLag: 500))
        #expect(adaptive.target == .milliseconds(500))
    }

    /// A decoder that never falls behind is asked for NOTHING. A floor
    /// here would be D-047's rejected insurance constant.
    @Test("a decoder that keeps up is asked for no cushion")
    func keepingUpAsksForNothing() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(audio: 2000, wall: 1200, worstLag: 0))
        #expect(adaptive.target == .zero)
    }

    /// A margin with no step record cannot size anything, and must say so
    /// rather than inventing a number from the totals it does have.
    @Test("no step record means no learned cushion, not a guessed one")
    func noRecordMeansNoCushion() {
        let adaptive = AdaptiveLead()
        adaptive.observe(DecodeMargin(audioMilliseconds: 2000,
                                      wallMilliseconds: 2500,
                                      prefillMilliseconds: 0,
                                      steadyRealTimeFactor: 1.25))
        #expect(adaptive.target == nil)
    }

    /// D-073's rule that survives: only FINISHED replies teach. A failed
    /// decode's numbers are honest but its length is however far it got,
    /// and one early failure would teach "replies are short".
    @Test("an unfinished reply still teaches nothing")
    func unfinishedTeachesNothing() {
        let adaptive = AdaptiveLead()
        adaptive.observe(DecodeMargin(audioMilliseconds: 400,
                                      wallMilliseconds: 900,
                                      prefillMilliseconds: 0,
                                      steadyRealTimeFactor: 2.25,
                                      completed: false,
                                      cushionMilliseconds: 0,
                                      worstLagMilliseconds: 500))
        #expect(adaptive.target == nil)
    }
}

/// 4o — AC-179. The first reply of a session has nothing measured to
/// learn from, so ONE constant speaks for it. This suite pins what that
/// constant is and what it costs, so the gap is a known number rather
/// than a surprise in a field report.
@Suite("the first reply's cushion is stated, not assumed")
struct FirstReplyCushionTests {

    /// Nothing learned yet means the learner says NOTHING — it does not
    /// invent a starting value. The fallback is the caller's decision,
    /// made in one visible place.
    @Test("a fresh learner offers no cushion at all")
    func freshLearnerIsSilent() {
        #expect(AdaptiveLead().target == nil)
        #expect(AdaptiveLead().typicalLength == nil)
    }

    /// THE PRICE, PINNED (INSTRUMENTS §54). The constant asks 396 ms on
    /// `.stepped`; the sweep measured a short reply needing 1600 ms to
    /// fall silent-free on the same levers. That is roughly a fourfold
    /// shortfall, and this test exists so a change to either number
    /// cannot quietly widen it.
    @Test("the Mac's first reply is under-cushioned, by a number we know")
    func theFirstReplyIsUnderCushioned() {
        let fallback = NeuralVoice.defaultLead(for: .stepped)
        #expect(fallback == .milliseconds(396))

        let measuredNeed = Duration.milliseconds(1600)     // §54.3a
        #expect(fallback < measuredNeed,
                "if this ever passes, §54's sweep and this constant have met — update both")
    }

    /// The other decoder keeps up on this Mac, so its first reply needs
    /// nothing — and the constant says so rather than banking anyway.
    @Test("a decoder that keeps up gets no first-reply cushion either")
    func fusedNeedsNoFallback() {
        #expect(NeuralVoice.defaultLead(for: .fused) == .zero)
    }
}
