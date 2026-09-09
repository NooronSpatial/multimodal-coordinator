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
        /// The seam's events VERBATIM, `.stopped` included — so a test can
        /// say what a source must never do (a token after its stop, two
        /// stops) and read what the run makes of it (4v, AC-235).
        case events([TokenEvent])
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

    /// Settable, because a test drives the door too. Typed since 4v, the
    /// same `ReplyFailure` the real door throws (AC-238).
    private let door = Mutex<ReplyFailure?>(nil)
    var unavailable: ReplyFailure? { door.withLock { $0 } }
    func makeUnavailable(_ failure: ReplyFailure) { door.withLock { $0 = failure } }

    init(_ plan: Plan) { self.plan = plan }

    var capExhausted: Bool { counts.withLock { $0.capExhausted } }
    /// True once cancellation actually REACHED this source's task — the
    /// deterministic fact that replaced an assertion measured to be inert.
    var sawCancellation: Bool { counts.withLock { $0.sawCancellation } }
    func release() { counts.withLock { $0.released = true } }

    func tokens(for context: ReplyContext) -> AsyncThrowingStream<TokenEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch plan {
                case .tokens(let all):
                    yieldAll(all, into: continuation)
                    continuation.finish()
                case .events(let all):
                    for event in all { continuation.yield(event) }
                    counts.withLock { $0.yielded += all.count }
                    continuation.finish()
                case .tokensThenThrow(let all, let error):
                    yieldAll(all, into: continuation)
                    continuation.finish(throwing: error)
                case .spinsUntilCancelled:
                    await spinUntilCancelled()
                    continuation.finish()
                case .finishesAfterRelease(let before):
                    await yieldThenHoldAtTheGate(before, into: continuation)
                    continuation.finish()
                case .gatedDefiance(let before, let after):
                    await yieldThenHoldAtTheGate(before, into: continuation)
                    // THE DEFIANT YIELD, after the test's cancel returned.
                    continuation.yield(.token(after))
                    counts.withLock { $0.yielded += 1 }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields every token in birth order, counting each one.
    private func yieldAll(
        _ all: [String],
        into continuation: AsyncThrowingStream<TokenEvent, any Error>.Continuation
    ) {
        for token in all {
            continuation.yield(.token(token))
            counts.withLock { $0.yielded += 1 }
        }
    }

    /// Spins until the run's task is cancelled, capped so a red test dies
    /// fast and never hangs. The caller finishes the stream either way.
    private func spinUntilCancelled() async {
        for _ in 0..<100_000 {
            if Task.isCancelled {
                counts.withLock { $0.sawCancellation = true }
                return
            }
            await Task.yield()
        }
        counts.withLock { $0.capExhausted = true }
    }

    /// Yields `before`, then holds at the gate until the TEST calls
    /// `release()` — capped, so an unreleased gate ends the test instead of
    /// hanging it. Shared by both gated plans.
    private func yieldThenHoldAtTheGate(
        _ before: String,
        into continuation: AsyncThrowingStream<TokenEvent, any Error>.Continuation
    ) async {
        continuation.yield(.token(before))
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
            .tokensThenThrow([], ReplyFailure.engine("the model died mid-thought")))
        try await ReplyConformanceKit.verifyFailureIsOneTerminal(mind)
    }

    // MARK: - promises that are this citizen's own

    @Test("the door is asked EVERY time — weights can arrive between turns")
    func theDoorIsAskedEveryTime() async throws {
        let (mind, source) = generator(.tokens(["hello"]))
        _ = try await mind.openReply(to: "first, while installed")
        source.makeUnavailable(.unavailable(.weightsAbsent))
        await #expect(throws: ReplyFailure.unavailable(.weightsAbsent)) {
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

    /// The internal seam's `.stopped` is a TERMINAL, the same word it is
    /// on the public one: the FIRST reason is the reason, and a token that
    /// arrives after it is a source breaking its contract — dropped, never
    /// spoken. The only real source today yields one `.stopped` last, so
    /// this pins the contract before a second source can drift from it.
    @Test("the FIRST .stopped is terminal — a later token or reason is not heard")
    func stoppedIsTerminalOnTheTokenSeam() async throws {
        let (mind, _) = generator(.events([
            .token("a"), .stopped(.complete), .token("LATE"), .stopped(.tokenBudget)
        ]))
        let run = try await mind.openReply(to: "a thought")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("a"), .finished(.complete)],
                "the reason is the first one said; nothing after it is admitted")
    }

    /// The words this mind's door used to own (`MLXUnavailable`) are the
    /// seam's now (4v): the door throws `ReplyFailure.unavailable` and
    /// its rendering is the verdict's, still spoken mid-sentence.
    ///
    /// THE WORDS ARE WRITTEN OUT, and the 4v review is why. The first
    /// version of this test asserted `refusal.description ==
    /// verdict.description` — which is the LINE `.unavailable` is defined
    /// by (`case .unavailable(let verdict): verdict.description`), so it
    /// could not fail for any input. What must be pinned is that the seam
    /// adds NOTHING of its own: no prefix, no "the mind is unavailable:",
    /// no re-capitalisation. A literal is the only assertion that catches
    /// that, so a literal is what this row carries.
    @Test("the door's refusal describes itself in the verdict's honest words, undecorated")
    func theDoorSpeaksTheVerdictsWords() {
        for (verdict, words): (MindUnavailable, String) in [
            (.weightsAbsent, "the on-device model is not installed yet"),
            (.deviceCannotRun(.noGPU), "this device has no GPU the on-device model can use"),
            (.installIncomplete(files: ["model.safetensors"]),
             "the on-device model's install is incomplete — 1 file(s) missing or short: model.safetensors")
        ] {
            let refusal = ReplyFailure.unavailable(verdict)
            #expect(refusal.description == words,
                    "the seam speaks the verdict's sentence WHOLE, and adds no words of its own")
            #expect(refusal.description.first?.isUppercase == false,
                    "these are spoken mid-sentence, not shouted")
        }
    }
}

// MARK: - AC-236: a typed failure thrown by the source is the run's failure

/// The source refuses a too-long prompt BEFORE generation by throwing
/// `ReplyFailure.contextWindowExceeded` (AC-236). The run must hand that
/// case on untouched — wrapping it in `.engine("local generation failed:
/// …")` would turn a countable case back into prose, which is the exact
/// thing F-3 = A was ruled against.
@Suite("AC-236 · a ReplyFailure thrown by the source keeps its case")
struct MLXTypedFailureTests {

    @Test("contextWindowExceeded thrown by the source is .failed(.contextWindowExceeded)")
    func typedFailurePassesThrough() async throws {
        let source = ScriptedTokenSource(.tokensThenThrow([], ReplyFailure.contextWindowExceeded))
        let mind = MLXReplyGenerator(source: source)
        let run = try await mind.openReply(to: "a prompt the window cannot hold")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.failed(.contextWindowExceeded)],
                "the case must survive the run; prose is not a case")
    }

    @Test("anything else the vendor throws is still .engine(String)")
    func untypedFailureIsEngine() async throws {
        struct VendorError: Error {}
        let source = ScriptedTokenSource(.tokensThenThrow(["a"], VendorError()))
        let mind = MLXReplyGenerator(source: source)
        let run = try await mind.openReply(to: "doomed")
        let updates = await ReplyConformanceKit.drain(run)
        guard case .failed(.engine(let words))? = updates.last else {
            Issue.record("expected .failed(.engine), got \(updates)"); return
        }
        #expect(words.hasPrefix("local generation failed: "))
    }
}
