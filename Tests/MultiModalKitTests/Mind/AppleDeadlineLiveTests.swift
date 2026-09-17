import Foundation
import Testing
@testable import MultiModalKit

/// AC-264's live half for the Apple mind: a REAL reply, a 200 ms deadline
/// on the real clock, and the ending is `.finished(.deadline)` with
/// whatever the model had said by then. Runtime-gated the way the Apple
/// kit is (OS 26), then gated again on the model being READY — on the Mac
/// this was written on (2026-09-12) the model reported `modelNotReady`,
/// so the skip SAYS SO and names what would make it real (the
/// `AppleMindLiveTests` rule). It is written anyway so it runs, unchanged,
/// the day the model is ready.
///
/// What this test does NOT measure: the memory the cancel frees. The
/// vendor's session owns its memory behind `LanguageModelSession`; this
/// library has no prefill of its own to release and no counter of the
/// vendor's to read. AC-264's "memory freed" clause is the MLX mind's,
/// measured with that engine's own `activeMemory` (INSTRUMENTS §68).
@Suite("live · the Apple mind's deadline against the real model",
       .timeLimit(.minutes(5)))
struct AppleDeadlineLiveTests {

    /// A SKIP THAT SAYS SO (the 4h review's finding, applied here).
    private static func skipping(_ verdict: MindUnavailable) -> Bool {
        print("SKIPPED (\(verdict)) — an OS-26 machine with the on-device model ready makes this test REAL")
        return true
    }

    /// A long story asked for with a 200 ms wall-clock budget and a large
    /// token budget, so the CLOCK is the only thing that can end it early:
    /// the stop must be `.deadline`, and the call must RETURN (an ending),
    /// not throw (a failure). The text is not asserted — how many words
    /// 200 ms buys is the model's business, and zero is a legal answer.
    @Test("a real reply with a 200 ms deadline ends .finished(.deadline) (AC-264)")
    func realReplyEndsAtTheDeadline() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let started = ContinuousClock.now
        let reply = try await AppleReplyGenerator().reply(to: ReplyContext(
            transcript: "Write a very long story about a lighthouse keeper, at least two thousand words.",
            options: MultiModalKit.GenerationOptions(maxTokens: 4096, temperature: 0,
                                                     deadline: .milliseconds(200))))
        let elapsed = ContinuousClock.now - started
        #expect(reply.stop == .deadline, "the clock ended it: \(reply.text.count) chars in \(elapsed)")
        print("live deadline: stop=\(reply.stop) chars=\(reply.text.count) elapsed=\(elapsed)")
    }
}
