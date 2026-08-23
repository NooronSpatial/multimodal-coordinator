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
