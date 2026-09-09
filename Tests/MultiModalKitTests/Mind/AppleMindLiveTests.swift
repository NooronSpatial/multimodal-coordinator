import Foundation
import Testing
@testable import MultiModalKit

/// The REAL Apple model, when this machine has one — AC-232 and AC-233
/// through the vendor, not the seam. Runtime-gated the way the Apple
/// kit is (OS 26), and then gated again on the model being READY: on
/// the Mac this was written on the model was `modelNotReady`, and a
/// test that returns early prints "passed" — so, as `MLXMindLiveTests`
/// does, the skip SAYS SO and names what would make it real.
@Suite("live · the Apple model, when this machine has one",
       .timeLimit(.minutes(5)))
struct AppleMindLiveTests {

    /// A SKIP THAT SAYS SO (the 4h review's finding, applied here).
    private static func skipping(_ verdict: MindUnavailable) -> Bool {
        print("SKIPPED (\(verdict)) — an OS-26 machine with the on-device model ready makes this test REAL")
        return true
    }

    /// AC-232 through the real session: the caller's per-call
    /// instructions decide the answer. A secret word only the
    /// instructions know is the plainest proof that they reached the
    /// model; greedy sampling (AC-234) keeps the answer stable.
    @Test("per-call instructions reach the real model (AC-232)")
    func perCallInstructionsReachTheModel() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let generator = AppleReplyGenerator(instructions: "Answer in one short sentence.")
        let reply = try await generator.reply(to: ReplyContext(
            transcript: "What is the secret word? Answer with only that word.",
            options: MultiModalKit.GenerationOptions(
                instructions: "The secret word is PINEAPPLE. When asked for it, answer with only that word.",
                temperature: 0)))
        #expect(reply.text.uppercased().contains("PINEAPPLE"), "got: \(reply.text)")
        #expect(reply.stop == .unreported, "the vendor reports no stop reason (AC-235)")
    }

    /// AC-233 through the real session: a tiny budget bounds the reply.
    /// The exact token count is the vendor's tokenizer's; the test asks
    /// only that a 1024-budget prompt for a long answer, capped at 8,
    /// comes back short — and non-empty, so the cap did not silence it.
    @Test("a per-call budget bounds the real reply (AC-233)")
    func perCallBudgetBoundsTheReply() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let reply = try await AppleReplyGenerator().reply(to: ReplyContext(
            transcript: "Write a long story about a lighthouse keeper.",
            options: MultiModalKit.GenerationOptions(maxTokens: 8, temperature: 0)))
        #expect(!reply.text.isEmpty)
        #expect(reply.text.count < 200, "8 tokens cannot be a long story: \(reply.text.count) chars")
    }
}
