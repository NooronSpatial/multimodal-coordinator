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

    static func margin(factor: Double) -> DecodeMargin {
        DecodeMargin(audioMilliseconds: 6000,
                     wallMilliseconds: 6000 * factor,
                     prefillMilliseconds: 100,
                     steadyRealTimeFactor: factor)
    }

    @Test("it knows nothing until something has been decoded")
    func nothingLearnedYet() {
        #expect(AdaptiveLead().target == nil)
    }

    @Test("the iPhone's measured 1.21 asks for about 1.26 s, not 396 ms")
    func thePhonesNumber() {
        let adaptive = AdaptiveLead()
        adaptive.observe(Self.margin(factor: 1.21))
        let learned = try! #require(adaptive.target)
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
