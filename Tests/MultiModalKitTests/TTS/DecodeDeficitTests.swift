import Testing
@testable import MultiModalKitTTS

/// 4o — AC-175. The statistic that replaces an average (D-080, F-1 = b).
///
/// Every value here is binary-exact: 0.25, 0.5, whole milliseconds. A
/// value like 0.02 has no exact binary form and drifts under arithmetic,
/// which turns a real failure into an argument about the last decimal.
@Suite("the cushion is what the bank had to hold")
struct DecodeDeficitTests {

    /// A decoder faster than the ear needs no WAIT beyond its first
    /// buffer. `requiredStart` is that first buffer's own wall time, and
    /// the cushion is the audio that exists by then — one step, which is
    /// what "start as soon as you have something" means to a player that
    /// can only begin on a buffer boundary.
    @Test("a decoder faster than the ear waits only for its first buffer")
    func fasterThanRealTimeWaitsForOneBuffer() {
        let steps = (0..<8).map { _ in
            DecodeStep(wallMilliseconds: 5, audioMilliseconds: 20)
        }
        #expect(DecodeDeficit.requiredStart(steps: steps) == 5)
        #expect(DecodeDeficit.cushion(steps: steps) == 20)
    }

    @Test("no steps at all is zero, not a guess")
    func emptyIsZero() {
        #expect(DecodeDeficit.requiredStart(steps: [DecodeStep]()) == 0)
        #expect(DecodeDeficit.cushion(steps: [DecodeStep]()) == 0)
    }

    /// THE REVIEW'S SECOND FINDING, PINNED. A step's audio arrives at the
    /// END of the step, so the bank bottoms out just BEFORE a slow step
    /// delivers. The first version credited the step's own audio at that
    /// instant and answered 900; the true requirement is 1100, reached at
    /// step 7 — elapsed 2100 with only 1000 ms ever delivered.
    @Test("the peak is measured before the slow step delivers, not after")
    func peakIsBeforeDelivery() {
        var steps = (0..<10).map { _ in
            DecodeStep(wallMilliseconds: 200, audioMilliseconds: 200)
        }
        steps.insert(DecodeStep(wallMilliseconds: 900, audioMilliseconds: 0), at: 5)
        #expect(DecodeDeficit.requiredStart(steps: steps) == 1100)
        // The value the buggy version returned, stated so the gap is
        // visible in the test rather than only in a commit message.
        #expect(DecodeDeficit.requiredStart(steps: steps) != 900)
    }

    /// F-1's REJECTED HALF, still rejected. Five 200 ms overruns in a row
    /// drain a bank exactly as one 1000 ms overrun does.
    @Test("consecutive small overruns accumulate — the worst STEP would miss them")
    func consecutiveOverrunsAccumulate() {
        let steps = (0..<5).map { _ in
            DecodeStep(wallMilliseconds: 400, audioMilliseconds: 200)
        }
        // Elapsed climbs 400 per step while audio climbs 200, and the
        // deepest instant is before the LAST step delivers: 2000 − 800.
        #expect(DecodeDeficit.requiredStart(steps: steps) == 1200)
        let worstSingleStep = steps
            .map { $0.wallMilliseconds - $0.audioMilliseconds }.max() ?? 0
        #expect(worstSingleStep == 200)
    }

    /// THE REVIEW'S FIRST FINDING, PINNED: pre-playback time is not
    /// deficit. A long wait before the first sound only delays the start;
    /// nothing is draining yet, so it must not be banked.
    @Test("a long prefill delays the start and is NOT banked as cushion")
    func prefillIsNotCushion() {
        // 2000 ms before the first samples, then a decoder that keeps up.
        var steps = [DecodeStep(wallMilliseconds: 2000, audioMilliseconds: 80)]
        steps += (0..<10).map { _ in
            DecodeStep(wallMilliseconds: 60, audioMilliseconds: 80)
        }
        // The start is late — that is the prefill, honestly reported.
        #expect(DecodeDeficit.requiredStart(steps: steps) == 2000)
        // But the CUSHION is only the audio that exists by then: one step.
        // The buggy version banked the whole 2000 ms and paid it in felt
        // pause on every following reply.
        #expect(DecodeDeficit.cushion(steps: steps) == 80)
    }

    /// A deficit repaid before the end still had to be banked — the
    /// endpoint reads zero and the audio breaks anyway.
    @Test("a deficit repaid before the end still had to be banked")
    func midRunPeakSurvivesRecovery() {
        let steps = [
            DecodeStep(wallMilliseconds: 800, audioMilliseconds: 0),
            DecodeStep(wallMilliseconds: 100, audioMilliseconds: 900)
        ]
        #expect(DecodeDeficit.requiredStart(steps: steps) == 900)
        let atTheEnd = steps.reduce(0.0) { $0 + $1.wallMilliseconds }
            - steps.reduce(0.0) { $0 + $1.audioMilliseconds }
        #expect(atTheEnd == 0)
    }

    /// A uniformly slow decoder: the requirement climbs steadily, so the
    /// deepest instant is before the last step delivers.
    @Test("a uniformly slow decode asks for its accumulated deficit")
    func uniformlySlowAccumulates() {
        let steps = (0..<10).map { _ in
            DecodeStep(wallMilliseconds: 250, audioMilliseconds: 200)
        }
        // elapsed 2500 against 1800 delivered before the last step.
        #expect(DecodeDeficit.requiredStart(steps: steps) == 700)
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
        // And it still could not start before wall 900 — at that instant
        // the second step's wall time has been spent and its samples have
        // NOT yet arrived, which is the moment the review found the first
        // version blind to.
        #expect(DecodeDeficit.requiredStart(steps: steps) == 900)
    }
}
