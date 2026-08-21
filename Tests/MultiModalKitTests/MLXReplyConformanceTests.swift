import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// MARK: - the scripted TOKEN source (the ScriptedSnapshotSource shape, one seam over)

/// A token stream the TEST drives — including the wrong thing, on
/// purpose. It reaches the internal `ReplyTokenStreaming` seam via
/// `@testable`, which is the D-053 shape: the second implementation of a
/// seam is a test double, so the seam stays internal.
final class ScriptedTokenSource: ReplyTokenStreaming, @unchecked Sendable {
    enum Plan: Sendable {
        case tokens([String])
        /// Yields, then throws — the failure a real model cannot be asked
        /// to perform on demand.
        case tokensThenThrow([String], any Error)
        /// Spins until the run's task is cancelled. Capped, so a red test
        /// dies fast and never hangs.
        case spinsUntilCancelled
        /// GATED DEFIANCE. Yields `before`, holds until the TEST calls
        /// `release()` — which it does only AFTER its cancel returned —
        /// then defiantly yields `after`, ignoring cancellation.
        ///
        /// The gate is what makes the promise DETERMINISTIC. The Apple
        /// seam's version of this test was measured flaking ~1 in 800
        /// because a PRE-cancel token is legal under the contract and
        /// survives `finish()` in the stream's buffer: "nothing after
        /// cancel" is the promise, not "nothing at all".
        case gatedDefiance(before: String, after: String)
        /// Yields `before`, holds at the gate, then finishes NORMALLY
        /// without a further token. This is the cancel-then-finish race:
        /// the run's loop ends of its own accord AFTER a cancel, and must
        /// still report nothing.
        case finishesAfterRelease(before: String)
    }

    private let plan: Plan
    private struct Counts {
        var yielded = 0
        var capExhausted = false
        var released = false
        var sawCancellation = false
    }
    private let counts = Mutex(Counts())

    /// Settable, because a test drives the door too.
    private let door = Mutex<(any Error)?>(nil)
    var unavailable: (any Error)? { door.withLock { $0 } }
    func makeUnavailable(_ error: any Error) { door.withLock { $0 = error } }

    init(_ plan: Plan) { self.plan = plan }

    var capExhausted: Bool { counts.withLock { $0.capExhausted } }
    /// True once cancellation actually REACHED this source's task — the
    /// deterministic fact that replaced an assertion measured to be inert.
    var sawCancellation: Bool { counts.withLock { $0.sawCancellation } }
    func release() { counts.withLock { $0.released = true } }

    func tokens(for prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch plan {
                case .tokens(let all):
                    for t in all {
                        continuation.yield(t)
                        counts.withLock { $0.yielded += 1 }
                    }
                    continuation.finish()
                case .tokensThenThrow(let all, let error):
                    for t in all {
                        continuation.yield(t)
                        counts.withLock { $0.yielded += 1 }
                    }
                    continuation.finish(throwing: error)
                case .spinsUntilCancelled:
                    for _ in 0..<100_000 {
                        if Task.isCancelled {
                            counts.withLock { $0.sawCancellation = true }
                            continuation.finish()
                            return
                        }
                        await Task.yield()
                    }
                    counts.withLock { $0.capExhausted = true }
                    continuation.finish()
                case .finishesAfterRelease(let before):
                    continuation.yield(before)
                    counts.withLock { $0.yielded += 1 }
                    var opened = false
                    for _ in 0..<200_000 {
                        if Task.isCancelled {
                            counts.withLock { $0.sawCancellation = true }
                        }
                        if counts.withLock({ $0.released }) { opened = true; break }
                        await Task.yield()
                    }
                    if !opened { counts.withLock { $0.capExhausted = true } }
                    continuation.finish()
                case .gatedDefiance(let before, let after):
                    continuation.yield(before)
                    counts.withLock { $0.yielded += 1 }
                    var opened = false
                    for _ in 0..<200_000 {
                        if Task.isCancelled {
                            counts.withLock { $0.sawCancellation = true }
                        }
                        if counts.withLock({ $0.released }) { opened = true; break }
                        await Task.yield()
                    }
                    if !opened { counts.withLock { $0.capExhausted = true } }
                    // THE DEFIANT YIELD, after the test's cancel returned.
                    continuation.yield(after)
                    counts.withLock { $0.yielded += 1 }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - AC-126: the kit, unchanged, applied to the SECOND citizen

/// The whole point of this suite is that it calls `ReplyConformanceKit`
/// with NO argument the Apple mind did not also pass. A seam whose second
/// implementation needs the promises loosened was never a seam.
@Suite("AC-126 · the second mind keeps the same five promises",
       .timeLimit(.minutes(1)))
struct MLXReplyGeneratorTests {

    private func generator(_ plan: ScriptedTokenSource.Plan)
    -> (MLXReplyGenerator, ScriptedTokenSource) {
        let source = ScriptedTokenSource(plan)
        return (MLXReplyGenerator(source: source), source)
    }

    @Test("promise 1 — tokens in birth order, then exactly one terminal")
    func tokensThenOneTerminal() async throws {
        let (mind, _) = generator(.tokens(["Rome", " is", " the capital."]))
        try await ReplyConformanceKit.verifyTokensThenExactlyOneTerminal(
            mind, expecting: ["Rome", " is", " the capital."])
    }

    @Test("promise 2 — a cancelled reply ends its stream WITHOUT a terminal")
    func cancelEndsWithoutATerminal() async throws {
        let (mind, _) = generator(.spinsUntilCancelled)
        try await ReplyConformanceKit.verifyCancelEndsWithoutATerminal(mind)
    }

    @Test("promise 3 — nothing AFTER the cancel survives, gated defiance")
    func nothingAfterTheCancelSurvives() async throws {
        let (mind, source) = generator(
            .gatedDefiance(before: "before", after: "AFTER-THE-CANCEL"))
        try await ReplyConformanceKit.verifyNothingAfterTheCancelSurvives(
            mind,
            releaseDefiance: { source.release() },
            cancellationSeen: { source.sawCancellation })
    }

    @Test("promise 4 — openReply hands off; generation never blocks the opener")
    func openReplyHandsOff() async throws {
        let (mind, _) = generator(.spinsUntilCancelled)
        try await ReplyConformanceKit.verifyOpenReplyHandsOff(mind)
    }

    @Test("promise 5 — a failing generation is ONE .failed, terminal")
    func failureIsOneTerminal() async throws {
        let (mind, _) = generator(
            .tokensThenThrow([], MLXUnavailable.unknown("the model died mid-thought")))
        try await ReplyConformanceKit.verifyFailureIsOneTerminal(mind)
    }

    // MARK: - promises that are this citizen's own

    @Test("the door is asked EVERY time — weights can arrive between turns")
    func theDoorIsAskedEveryTime() async throws {
        let (mind, source) = generator(.tokens(["hello"]))
        _ = try await mind.openReply(to: "first, while installed")
        source.makeUnavailable(MLXUnavailable.weightsNotInstalled("Qwen3-0.6B-4bit"))
        await #expect(throws: MLXUnavailable.self) {
            _ = try await mind.openReply(to: "second, after the weights vanished")
        }
    }

    /// The detokenizer yields "" while a multi-token character is still
    /// incomplete — accented text is exactly where that happens. An empty
    /// token is not a word, and must never reach the mouth as one.
    @Test("an EMPTY token is never spoken — the incomplete-character case")
    func emptyTokensAreNotWords() async throws {
        let (mind, _) = generator(.tokens(["Genè", "", "ve"]))
        try await ReplyConformanceKit.verifyTokensThenExactlyOneTerminal(
            mind, expecting: ["Genè", "ve"])
    }

    /// The cancel-then-finish race, made deterministic by the gate: the
    /// source's stream ends NORMALLY after the cancel, so the run's loop
    /// falls through to its `.finished` path. Nothing may come out.
    ///
    /// Note honestly what this test does and does not prove: it pins the
    /// BEHAVIOUR, and mutation shows the behaviour survives removing the
    /// retire latch — because `out.finish()` already dropped the yield.
    /// It is the finish that is load-bearing here, and this test would
    /// catch the finish going missing.
    @Test("a source that finishes AFTER the cancel still reports no terminal")
    func finishingAfterCancelReportsNothing() async throws {
        let (mind, source) = generator(.finishesAfterRelease(before: "before"))
        let run = try await mind.openReply(to: "a thought cut short")
        let seen = Mutex<[ReplyUpdate]>([])
        let ended = Mutex(false)
        let collector = Task {
            for await update in run.updates { seen.withLock { $0.append(update) } }
            ended.withLock { $0 = true }
        }
        // BOUNDED, always. The first version of this test awaited the
        // collector's result, and a mutation that removed `out.finish()`
        // HUNG it instead of reddening it — ten minutes, no verdict. A red
        // that hangs is a red nobody reads: the house `until` caps it.
        defer { collector.cancel() }
        #expect(await ReplyConformanceKit.until { !seen.withLock { $0.isEmpty } },
                "the legitimate pre-cancel token must arrive first")
        await run.cancel()
        source.release()
        #expect(await ReplyConformanceKit.until { ended.withLock { $0 } },
                "a cancelled reply's stream must END")
        #expect(ReplyConformanceKit.terminals(in: seen.withLock { $0 }).isEmpty,
                "a cancelled reply never claims completion, even when its source ends politely a moment later")
    }

    @Test("every unavailability reason describes itself in honest words")
    func reasonsSpeakPlainly() {
        for reason: MLXUnavailable in [
            .weightsNotInstalled("Qwen3-0.6B-4bit"),
            .platformCannotRunMLX,
            .unknown("something new"),
        ] {
            #expect(!reason.description.isEmpty)
            #expect(reason.description.first?.isUppercase == false,
                    "these are spoken mid-sentence, not shouted")
        }
    }
}
