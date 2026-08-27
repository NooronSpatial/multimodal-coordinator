import Testing
@testable import MultiModalKitTTS

/// 4o — AC-175. The statistic that replaces an average (D-080, F-1 = b).
///
/// Every value here is binary-exact: 0.25, 0.5, whole milliseconds. A
/// value like 0.02 has no exact binary form and drifts under arithmetic,
/// which turns a real failure into an argument about the last decimal.
@Suite("the cushion covers the worst lag, not the average")
struct DecodeDeficitTests {

    /// A decoder that keeps up needs no bank, and is told so — a floor
    /// here would be D-047's rejected insurance constant wearing a
    /// different hat.
    @Test("a decoder faster than the ear asks for nothing")
    func fasterThanRealTimeAsksForNothing() {
        let steps = (0..<8).map { _ in
            DecodeStep(wallMilliseconds: 5, audioMilliseconds: 20)
        }
        #expect(DecodeDeficit.worstLag(steps: steps) == 0)
    }

    @Test("no steps at all is zero, not a guess")
    func emptyIsZero() {
        #expect(DecodeDeficit.worstLag(steps: [DecodeStep]()) == 0)
    }

    /// THE CASE THE OLD RULE COULD NOT SEE.
    ///
    /// A fast decode with ONE stall in the middle. The average is nearly
    /// perfect — 4000 ms of audio in 4900 ms of wall, a steady factor of
    /// 1.225 — but the bank has to survive the stall itself.
    @Test("one deliberate stall is reported whole, not averaged away")
    func oneStallIsNotAveragedAway() {
        var steps = (0..<10).map { _ in
            DecodeStep(wallMilliseconds: 200, audioMilliseconds: 200)
        }
        // The stall: 900 ms of wall time producing nothing.
        steps.insert(DecodeStep(wallMilliseconds: 900, audioMilliseconds: 0),
                     at: 5)
        #expect(DecodeDeficit.worstLag(steps: steps) == 900)
    }

    /// F-1's REJECTED HALF, pinned so it cannot come back.
    ///
    /// Five 200 ms overruns in a row drain a bank exactly as one 1000 ms
    /// overrun does. A per-step maximum would answer 200 here and
    /// under-size by 5×; the running maximum answers 1000.
    @Test("consecutive small overruns accumulate — the worst STEP would miss them")
    func consecutiveOverrunsAccumulate() {
        let steps = (0..<5).map { _ in
            DecodeStep(wallMilliseconds: 400, audioMilliseconds: 200)
        }
        #expect(DecodeDeficit.worstLag(steps: steps) == 1000)
        // And the number a per-step rule would have produced, stated so
        // the gap between the two is visible in the test itself.
        let worstSingleStep = steps
            .map { $0.wallMilliseconds - $0.audioMilliseconds }.max() ?? 0
        #expect(worstSingleStep == 200)
    }

    /// The peak can arrive in the MIDDLE and be paid back before the end.
    /// Sizing from the endpoint — which is what `length × (RTF − 1)` does
    /// — reads zero here, and the audio would break anyway.
    @Test("a deficit repaid before the end still had to be banked")
    func midRunPeakSurvivesRecovery() {
        let steps = [
            DecodeStep(wallMilliseconds: 800, audioMilliseconds: 0),    // stall
            DecodeStep(wallMilliseconds: 100, audioMilliseconds: 900)   // catches up
        ]
        #expect(DecodeDeficit.worstLag(steps: steps) == 800)
        // The endpoint the old rule would have used: elapsed 900,
        // produced 900 — a deficit of zero, and a broken sentence.
        let atTheEnd = steps.reduce(0.0) { $0 + $1.wallMilliseconds }
            - steps.reduce(0.0) { $0 + $1.audioMilliseconds }
        #expect(atTheEnd == 0)
    }

    /// A uniformly slow decoder is the case where the OLD rule was right,
    /// and it must stay right: under a constant rate the running maximum
    /// IS the endpoint. This is the test that says uniformity was the
    /// false assumption, not the arithmetic.
    @Test("under a uniform rate the new rule agrees with the old one")
    func uniformRateAgreesWithTheOldRule() {
        let steps = (0..<10).map { _ in
            DecodeStep(wallMilliseconds: 250, audioMilliseconds: 200)
        }
        let audio = 10.0 * 200          // 2000 ms produced
        let factor = 2500.0 / audio     // steady RTF 1.25, exactly
        let oldRule = audio * (factor - 1)
        #expect(DecodeDeficit.worstLag(steps: steps) == 500)
        #expect(oldRule == 500)
    }
}

/// 4o — AC-177. `keepsUp` survives D-080, and is now pinned.
///
/// The criterion said "the existing expectations still pass, byte for
/// byte". There were none: `keepsUp` had no test and no caller anywhere
/// in the repo. So this suite is AC-177 paid honestly rather than
/// declared — the flag is the ONE part of the retired rule's machinery
/// that measurement vindicated, and it was resting on nothing.
///
/// INSTRUMENTS §53 is the evidence: across six measured configurations,
/// every one with a steady factor below 1.0 produced zero digital
/// silence, and both above it starved. The flag was right every time; it
/// was its use as a SIZING formula that was wrong (D-080).
@Suite("keeps-up is a flag, and it stayed one")
struct KeepsUpTests {

    static func margin(factor: Double) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: 1000,
                     wallMilliseconds: 1000 * factor,
                     prefillMilliseconds: 0,
                     steadyRealTimeFactor: factor)
    }

    /// §53's own numbers, both sides of the line. These are the measured
    /// medians for 0.6B on this Mac, not invented values.
    @Test("the configurations that never starved all read keepsUp")
    func measuredFastConfigurationsKeepUp() {
        // A · fused + latency (0.757) · F · fused + throughput (0.877)
        #expect(Self.margin(factor: 0.757).keepsUp)
        #expect(Self.margin(factor: 0.877).keepsUp)
    }

    @Test("the configurations that DID starve all read not-keepsUp")
    func measuredSlowConfigurationsDoNot() {
        // D · stepped + throughput (1.114) · B · stepped + latency (1.004)
        #expect(!Self.margin(factor: 1.114).keepsUp)
        #expect(!Self.margin(factor: 1.004).keepsUp)
    }

    /// The boundary, stated: exactly 1.0 does NOT keep up. A decoder
    /// running at precisely real time has no margin for the next stall,
    /// and the flag must not call that safe.
    @Test("exactly real time is not keeping up")
    func exactlyRealTimeIsNotSafe() {
        #expect(!Self.margin(factor: 1.0).keepsUp)
        #expect(Self.margin(factor: 0.999).keepsUp)
    }

    /// THE SEPARATION D-080 RULED, in one test: the flag and the cushion
    /// now answer different questions from different data. A decode can
    /// keep up on average and still have stalled badly enough to need a
    /// bank — which is the whole reason the average was retired as a
    /// sizing input.
    @Test("a decode can keep up on average and still have needed a cushion")
    func keepingUpDoesNotMeanNoCushion() {
        let steps = [
            DecodeStep(wallMilliseconds: 800, audioMilliseconds: 0),
            DecodeStep(wallMilliseconds: 100, audioMilliseconds: 1400)
        ]
        // 1400 ms of audio in 900 ms of wall: comfortably faster than the
        // ear, and the flag says so.
        #expect(Self.margin(factor: 900.0 / 1400.0).keepsUp)
        // And it still ran 800 ms dry in the middle.
        #expect(DecodeDeficit.worstLag(steps: steps) == 800)
    }
}
