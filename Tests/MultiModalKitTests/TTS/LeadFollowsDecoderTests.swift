import Foundation
import Testing

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS
import TTSKit

/// THE LEAD MUST FOLLOW THE DECODER — now with a test that says so.
///
/// The derivation exists because it once did not: a caller who asked for
/// `.stepped` silently kept `.fused`'s cushion of nothing, the player ran
/// dry from the first buffer, and the speech came out slow. That was fixed
/// in `NeuralVoice.init` (D-046's finding, arriving twice).
///
/// **It was fixed without a test, and the hole reopened somewhere else.**
/// `bakeoff voice-spike` passed `NeuralVoice.defaultLead` — the CONSTANT,
/// derived from `.fused`'s 0.752, which is zero — as an explicit argument,
/// and an explicit argument defeats the derivation by design. So the
/// instrument built to measure the decoders measured `--stepped` with no
/// cushion, under the very comment warning about it.
///
/// The trap is the shape of the API: a constant `defaultLead` sits beside a
/// function `defaultLead(for:)`, and the constant reads like the safe
/// choice. These tests do not remove the trap. They make falling into it
/// fail here instead of in a measurement nobody re-runs.
@Suite("the lead follows the decoder")
struct LeadFollowsDecoderTests {

    @Test("`.fused` needs no cushion — it decodes faster than the ear drinks")
    func fusedDerivesZero() {
        let voice = NeuralVoice(multiCodeDecoderMode: .fused)
        #expect(voice.lead == .zero)
    }

    @Test("`.stepped` needs one — it decodes slower than real time")
    func steppedDerivesNonZero() {
        let voice = NeuralVoice(multiCodeDecoderMode: .stepped)
        #expect(voice.lead > .zero,
                "RTF 1.066 starves the player; a zero cushion is the slow-voice bug")
    }

    @Test("the two decoders do NOT get the same cushion")
    func theCushionsDiffer() {
        let fused = NeuralVoice(multiCodeDecoderMode: .fused)
        let stepped = NeuralVoice(multiCodeDecoderMode: .stepped)
        #expect(fused.lead != stepped.lead)
    }

    @Test("an explicit lead still wins — the derivation is a default, not a law")
    func explicitLeadWins() {
        let voice = NeuralVoice(lead: .milliseconds(250),
                                multiCodeDecoderMode: .stepped)
        #expect(voice.lead == .milliseconds(250))
    }

    @Test("measuredRealTimeFactor provides platform-calibrated values")
    func platformCalibratedRTF() {
        #if os(iOS)
        #expect(NeuralVoice.measuredRealTimeFactor(for: .fused) >= 1.2)
        #expect(NeuralVoice.defaultLead(for: .fused) >= .milliseconds(1500))
        #else
        #expect(NeuralVoice.measuredRealTimeFactor(for: .fused) == 0.752)
        #expect(NeuralVoice.defaultLead(for: .fused) == .zero)
        #endif
    }

    /// THE BUG, PINNED. Not a wish — a statement of what the API does, so
    /// that anyone reading `defaultLead` as "the safe default" sees the
    /// cost written down next to it.
    /// DELIBERATELY deprecated, so it may name the deprecated thing.
    ///
    /// Swift has no per-expression suppression; a deprecated context is the
    /// only way to reference deprecated API without a warning. And under
    /// CI's `-warnings-as-errors` a warning is a build failure — which this
    /// test caused: the deprecation added as the guard for the slow-voice
    /// bug broke the test written to document that guard. Found by the 4j
    /// review, and it had survived `swift build -Xswiftc
    /// -warnings-as-errors` (Sources are clean) and a plain `swift test`
    /// (no flag). Neither is what CI runs. VERIFY WITH THE COMMAND CI USES.
    @available(*, deprecated, message: "documents the deprecated constant on purpose")
    @Test("the CONSTANT is `.fused`'s cushion, and passing it to `.stepped` is the bug")
    func theConstantIsFusedsCushion() {
        #expect(NeuralVoice.defaultLead == .zero)
        let trapped = NeuralVoice(lead: NeuralVoice.defaultLead,
                                  multiCodeDecoderMode: .stepped)
        let correct = NeuralVoice(multiCodeDecoderMode: .stepped)
        #expect(trapped.lead == .zero)
        #expect(trapped.lead != correct.lead,
                "if these are ever equal the derivation has stopped working")
    }
}
#endif

/// D-068: the cushion is learned from the machine, and a human still wins.
///
/// The constant it replaces is a Mac's. The iPhone measured 1.21 where the
/// constant says 1.066 (INSTRUMENTS §33), which on a six-second reply is
/// 396 ms of cushion against the ~1260 ms the phone needs — so the phone
/// runs dry mid-reply, which is the failure this whole strand keeps
/// producing in new disguises.
@Suite("the lead learns from the machine")
struct AdaptiveLeadTests {

    /// A UNIFORMLY slow decode of a six-second reply.
    ///
    /// The `worstLag` is stated rather than derived, and for a uniform
    /// rate it is exactly what the retired rule computed: the deficit
    /// climbs steadily, so its running maximum is its endpoint,
    /// `6000 × (factor − 1)`. That is why these tests keep their old
    /// expected values after D-080 — under uniformity the two rules
    /// agree, and this helper is the uniform case.
    ///
    /// The cases where they DIVERGE — a stall repaid before the end — are
    /// in `AdaptiveLeadFollowsStallTests`, because this helper cannot
    /// express them: a single whole-run number has no shape.
    static func margin(factor: Double) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: 6000,
                     wallMilliseconds: 6000 * factor,
                     prefillMilliseconds: 100,
                     steadyRealTimeFactor: factor,
                     completed: true,
                     cushionMilliseconds: nil,
                     requiredCushionMilliseconds: max(0, 6000 * (factor - 1)))
    }

    @Test("it knows nothing until something has been decoded")
    func nothingLearnedYet() {
        #expect(AdaptiveLead().target == nil)
    }

    @Test("the iPhone's measured 1.21 asks for about 1.26 s, not 396 ms")
    func thePhonesNumber() throws {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(factor: 1.21))
        // `throws` + `try`, not `try!`: a force-try here kills the whole
        // test PROCESS with signal 5 instead of failing this one test red,
        // taking every later suite down with it (the same trap already
        // documented in ColdCompileTests).
        let learned = try #require(adaptive.target)
        #expect(learned > .milliseconds(1200))
        #expect(learned < .milliseconds(1300))
        #expect(learned > NeuralVoice.defaultLead(for: .stepped),
                "the constant under-cushions this machine — that is the point")
    }

    @Test("a machine that keeps up is given no cushion at all")
    func fastMachineNeedsNothing() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(factor: 0.752))
        #expect(adaptive.target == .zero)
    }

    @Test("the most recent reply wins — a bad sample costs one reply, not a session")
    func latestWins() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(factor: 1.5))     // a thermal spike
        let hot = adaptive.target
        adaptive.observe(Self.margin(factor: 1.06))    // it cooled down
        #expect(adaptive.target != hot)
        #expect(adaptive.target! < hot!, "a maximum would have kept the spike forever")
    }

    @Test("forget puts it back to knowing nothing")
    func forgetting() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(factor: 1.21))
        adaptive.forget()
        #expect(adaptive.target == nil)
    }

    // MARK: precedence — D-068 A and D together

    @Test("before any reply, the voice uses the decoder's constant")
    func startsFromTheConstant() {
        let voice = NeuralVoice(multiCodeDecoderMode: .stepped)
        #expect(voice.currentLead == NeuralVoice.defaultLead(for: .stepped))
    }

    @Test("after a reply, the voice uses what THIS machine managed")
    func learnsFromItsOwnReplies() {
        let voice = NeuralVoice(multiCodeDecoderMode: .stepped)
        voice.adaptive.observe(Self.margin(factor: 1.21))
        #expect(voice.currentLead > NeuralVoice.defaultLead(for: .stepped))
        #expect(voice.currentLead == voice.adaptive.target)
    }

    @Test("a human's number outranks the machine's — D-068 D")
    func explicitBeatsLearned() {
        let voice = NeuralVoice(lead: .milliseconds(250),
                                multiCodeDecoderMode: .stepped)
        voice.adaptive.observe(Self.margin(factor: 1.21))
        #expect(voice.currentLead == .milliseconds(250),
                "the lever on screen must not be silently overruled")
    }

    @Test("`lead` still reports what the voice was born with")
    func birthLeadIsUnchanged() {
        let voice = NeuralVoice(multiCodeDecoderMode: .stepped)
        let born = voice.lead
        voice.adaptive.observe(Self.margin(factor: 1.21))
        #expect(voice.lead == born, "the two properties answer different questions")
        #expect(voice.currentLead != born)
    }
}

/// 4m, D-073: the cushion learns the CONVERSATION as well as the machine.
///
/// §48's conviction: the formula was right and its input was wrong — a
/// fixed 6-second nominal while Ryad's mind answered at twenty, so at RTF
/// 1.06 the bank held 360 ms of the 1200 the reply needed, ran dry, and
/// the ear heard "weird … slow".
///
/// Two learned numbers, two estimators, on purpose: the RTF stays
/// latest-wins (a property of the MACHINE — thermals drift, the newest
/// sample is the truth of now); the length is the mean of the last four
/// (a property of the CONVERSATION — one short "yes" must not shrink the
/// cushion right before the next long answer). All values binary-exact:
/// RTF 1.25 and whole-second lengths, so deficit arithmetic is exact.
@Suite("the lead learns the conversation")
struct AdaptiveLengthTests {

    static func margin(length: Double, factor: Double = 1.25) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: length,
                     wallMilliseconds: length * factor,
                     prefillMilliseconds: 100,
                     steadyRealTimeFactor: factor,
                     completed: true,
                     cushionMilliseconds: nil,
                     requiredCushionMilliseconds: max(0, length * (factor - 1)))
    }

    // ⚠️ WHAT D-080 CHANGED ABOUT THIS SUITE.
    //
    // These tests were 4m's thesis: the cushion is sized from a WINDOW of
    // reply lengths. D-080 retired that as the SIZING input — INSTRUMENTS
    // §53 measured the rule predicting 1248 ms where 5593 ms of silence
    // occurred — and the cushion now comes from the decode's measured
    // worst stall instead.
    //
    // The window itself was NOT deleted, and these tests were not
    // rewritten into weaker claims. They still assert exactly what 4m
    // proved — that the window learns this conversation's lengths, means
    // them, and lets one monologue fade over four turns — through
    // `typicalLength`. What changed is what that number is FOR: it prices
    // the un-cushioned first reply (AC-179) rather than sizing every
    // cushion.
    //
    // The values below are unchanged because this helper is the UNIFORM
    // case, where the running maximum equals the endpoint and both rules
    // agree. `AdaptiveLeadFollowsStallTests` holds the cases where they
    // diverge.

    @Test("the reply's LENGTH reaches the window — the assertion §48 was missing")
    func lengthReachesTheCushion() {
        let short = AdaptiveLead()
        short.observe(Self.margin(length: 4000))
        let long = AdaptiveLead()
        long.observe(Self.margin(length: 8000))
        #expect(short.typicalLength != long.typicalLength,
                "identical except for length — a learner that reads them the same is reading a constant")
        #expect(short.typicalLength == .milliseconds(4000))
        #expect(long.typicalLength == .milliseconds(8000))
    }

    @Test("the window is the MEAN of the last four lengths")
    func meanOfTheWindow() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 4000))
        adaptive.observe(Self.margin(length: 8000))
        // mean(4 s, 8 s) = 6 s
        #expect(adaptive.typicalLength == .milliseconds(6000))
    }

    /// AC-165 — one long reply protects the next ones, then fades as the
    /// window refills. Both directions asserted with exact values.
    @Test("a long reply raises the cushion, and four short ones retire it")
    func longReplyFades() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 20000))
        #expect(adaptive.typicalLength == .milliseconds(20000))   // 20 s alone
        adaptive.observe(Self.margin(length: 4000))
        adaptive.observe(Self.margin(length: 4000))
        adaptive.observe(Self.margin(length: 4000))
        // window [20, 4, 4, 4] → mean 8 s: the monologue still counts
        #expect(adaptive.typicalLength == .milliseconds(8000))
        adaptive.observe(Self.margin(length: 4000))
        // window [4, 4, 4, 4] → mean 4 s: the monologue has left
        #expect(adaptive.typicalLength == .milliseconds(4000))
    }

    /// The teach-back split, asserted: length is windowed, RTF is latest.
    @Test("the RTF stays latest-wins while the length is windowed")
    func twoEstimators() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 8000, factor: 1.5))
        adaptive.observe(Self.margin(length: 4000, factor: 1.25))
        // mean(8 s, 4 s) = 6 s in the window, while the CUSHION is the
        // latest reply's measured stall — 4000 × 0.25 — and owes nothing
        // to the 8 s reply before it.
        #expect(adaptive.typicalLength == .milliseconds(6000))
        #expect(adaptive.target == .milliseconds(1000))
    }

    /// AC-166 — forget forgets the lengths too, not just the size: the
    /// next observation after a decoder change starts a fresh window.
    @Test("forget empties the window — no lengths survive a decoder change")
    func forgetForgetsLengths() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 20000))
        adaptive.forget()
        #expect(adaptive.target == nil)
        adaptive.observe(Self.margin(length: 4000))
        // ON THE WINDOW, not on the cushion (the 4o review's finding).
        // Since D-080 the cushion is the last reply's own measured need,
        // so it reads 1000 whether or not the 20 s survived — the
        // assertion could no longer fail for the reason it was written.
        // `typicalLength` is what forget() actually has to clear.
        #expect(adaptive.typicalLength == .milliseconds(4000),
                "a window still holding the 20 s would say mean 12 s")
        #expect(adaptive.target == .milliseconds(1000))
    }
}

/// The 4m review's two confirmed findings, pinned so they stay fixed.
@Suite("what the learner refuses to learn")
struct LearnerRefusalTests {

    /// The uniform-rate margin, same shape as `AdaptiveLeadTests`': under a
    /// constant rate the running maximum IS the endpoint, so `worstLag`
    /// is `length × (factor − 1)`.
    static func margin(length: Double, factor: Double = 1.25) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: length,
                     wallMilliseconds: length * factor,
                     prefillMilliseconds: 100,
                     steadyRealTimeFactor: factor,
                     completed: true,
                     cushionMilliseconds: nil,
                     requiredCushionMilliseconds: max(0, length * (factor - 1)))
    }

    /// A failed decode's truncated length must not poison the window.
    /// The review walked the chain: NeuralVoiceRun reports a margin on the
    /// `.failed` terminal too, with `audioMilliseconds` equal to however
    /// much audio existed at the throw — one transient failure 2 s into a
    /// 20 s answer would have taught "replies are short" and under-banked
    /// the next four cushions, the exact §48 direction.
    @Test("a failed run teaches nothing — its truncated length stays out of the window")
    func failedRunTeachesNothing() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 20000))
        #expect(adaptive.target == .milliseconds(5000))
        #expect(adaptive.typicalLength == .milliseconds(20000))
        adaptive.observe(DecodeMargin(audioMilliseconds: 2000,
                                      wallMilliseconds: 2500,
                                      prefillMilliseconds: 100,
                                      steadyRealTimeFactor: 1.25,
                                      completed: false,
                                      cushionMilliseconds: nil,
                                      requiredCushionMilliseconds: 500))
        #expect(adaptive.target == .milliseconds(5000),
                "a failed run's 500 ms stall must not replace a finished run's 5000")
        #expect(adaptive.typicalLength == .milliseconds(20000),
                "the poisoned window would say mean 11 s — and AC-179 prices the first reply from it")
    }

    @Test("a failed run before any finished one leaves the learner empty")
    func failedRunAloneLeavesNil() {
        let adaptive = AdaptiveLead()
        adaptive.observe(DecodeMargin(audioMilliseconds: 2000,
                                      wallMilliseconds: 2500,
                                      prefillMilliseconds: 100,
                                      steadyRealTimeFactor: 1.25,
                                      completed: false))
        #expect(adaptive.target == nil,
                "a first impression formed by a failure is still a first impression")
    }

    /// The suite's blind spot the review found by running the mutant: every
    /// multi-factor sequence was DESCENDING, so a min-ratchet estimator —
    /// keep the best RTF ever seen — survived all 377 tests. In the field
    /// that mutant sizes a hot phone's cushion from its coolest moment:
    /// session starts at 1.06, throttles to 1.5, and every cushion banks
    /// 360 ms where 3000 is needed. This is the rising half of latest-wins.
    @Test("the cushion RISES when the machine slows — latest-wins in the harmful direction")
    func rtfRises() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(length: 6000, factor: 1.06))
        adaptive.observe(Self.margin(length: 6000, factor: 1.5))
        // The hot reply's own stall — 6000 × 0.5 — and the cool one before
        // it buys no discount.
        #expect(adaptive.target == .milliseconds(3000),
                "a min-ratchet would still say 360 ms and the hot phone runs dry")
    }
}
