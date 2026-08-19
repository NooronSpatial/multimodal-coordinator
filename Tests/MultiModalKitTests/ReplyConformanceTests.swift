import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import MultiModalKit

/// THE REPLY CONFORMANCE KIT (SPEC 4f §73, the D-017 pattern's third
/// seam): the promises every self-generating `ReplyRun` must keep. The
/// scripted generator is test-driven by design, so the kit does not apply
/// to it — the same note `SynthesizerConformanceKit` carries.
enum ReplyConformanceKit {

    static func drain(_ run: any ReplyRun) async -> [ReplyUpdate] {
        var collected: [ReplyUpdate] = []
        for await update in run.updates { collected.append(update) }
        return collected
    }

    /// For the CANCEL-side promises, where the contract is that the
    /// stream ENDS: an unbounded drain would turn a broken cancel into a
    /// 60-second suite-limit death, and a red test must fail FAST. The
    /// mutation that removes cancel's finish was measured doing exactly
    /// that — three tests red at 60 s each — before this bound existed.
    static func drainBounded(_ run: any ReplyRun,
                             within: Duration = .seconds(5)) async -> [ReplyUpdate]? {
        let box = Mutex<[ReplyUpdate]>([])
        let ended = Mutex(false)
        let collector = Task {
            for await update in run.updates { box.withLock { $0.append(update) } }
            ended.withLock { $0 = true }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if ended.withLock({ $0 }) { return box.withLock { $0 } }
            await Task.yield()
        }
        collector.cancel()
        return nil   // the stream never ended — the caller names that failure
    }

    static func terminals(in updates: [ReplyUpdate]) -> [ReplyUpdate] {
        updates.filter {
            if case .token = $0 { return false } else { return true }
        }
    }

    /// Promise 1: tokens as they are born, then EXACTLY one terminal,
    /// then the stream ends — `drain` returning at all is the ending.
    static func verifyTokensThenExactlyOneTerminal(
        _ generator: any ReplyGenerating, expecting tokens: [String]
    ) async throws {
        let run = try await generator.openReply(to: "a final transcript")
        let updates = await drain(run)
        #expect(updates == tokens.map { .token($0) } + [.finished])
    }

    /// Promise 2: a cancelled reply ends its stream WITHOUT a terminal.
    static func verifyCancelEndsWithoutATerminal(
        _ generator: any ReplyGenerating
    ) async throws {
        let run = try await generator.openReply(to: "about to be interrupted")
        await run.cancel()
        guard let updates = await drainBounded(run) else {
            Issue.record("a cancelled reply's stream must END"); return
        }
        #expect(terminals(in: updates).isEmpty,
                "a cancelled reply reports no terminal — the seam's contract")
    }

    /// Promise 3: NOTHING survives the cancel — a defiant source that
    /// keeps producing snapshots into a dead run reaches no listener.
    /// The flag is the guarantee; cancelling the work is the optimisation.
    static func verifyNothingSurvivesTheCancel(
        _ generator: any ReplyGenerating
    ) async throws {
        let run = try await generator.openReply(to: "the ghost's transcript")
        await run.cancel()
        guard let updates = await drainBounded(run) else {
            Issue.record("a cancelled reply's stream must END"); return
        }
        #expect(updates.isEmpty, "a dead run must be SILENT, not merely terminal-free")
    }

    /// Promise 4: `openReply` HANDS OFF. The coordinator awaits it inline
    /// on its one serial loop, so an open that waits for generation is
    /// 4e's barge bug one seam over. Proven by reaching the next line
    /// while the source is still mid-stream.
    static func verifyOpenReplyHandsOff(
        _ generator: any ReplyGenerating
    ) async throws {
        let run = try await generator.openReply(to: "a long thought")
        // Reached: open returned while the scripted source is still
        // spinning. The cancel below is what releases it.
        await run.cancel()
        guard let updates = await drainBounded(run) else {
            Issue.record("a cancelled reply's stream must END"); return
        }
        #expect(terminals(in: updates).isEmpty)
    }

    /// Promise 5: a failing generation is ONE `.failed`, terminal, end.
    static func verifyFailureIsOneTerminal(
        _ generator: any ReplyGenerating
    ) async throws {
        let run = try await generator.openReply(to: "doomed")
        let updates = await drain(run)
        let ends = terminals(in: updates)
        #expect(ends.count == 1)
        if case .failed = ends.first {} else {
            Issue.record("the one terminal must be .failed, got \(ends)")
        }
    }
}

// MARK: - the scripted source (the TTSDecoding precedent, one seam over)

/// A snapshot stream the TEST drives — including the wrong thing, on
/// purpose. It reaches the internal `ReplySnapshotStreaming` seam via
/// `@testable`, which is the D-053 shape: the second implementation is a
/// test double, so the seam stays internal.
final class ScriptedSnapshotSource: ReplySnapshotStreaming, @unchecked Sendable {
    enum Plan: Sendable {
        /// Yields these cumulative snapshots, then finishes.
        case snapshots([String])
        /// Yields, then throws — the failure a real model cannot be
        /// asked to perform (AC-114's whole reason).
        case snapshotsThenThrow([String], any Error)
        /// Spins until the run's task is cancelled — the hands-off and
        /// cancel cases. Capped, so a red test dies fast, never hangs.
        case spinsUntilCancelled
        /// DEFIANT: ignores cancellation and keeps yielding — proof duty
        /// for the retired flag, the same job the defiant mocks do for
        /// the turn ticket.
        case defiantSnapshots([String])
    }

    var unavailable: (any Error)? { nil }

    private let plan: Plan
    private struct Counts { var yielded = 0; var capExhausted = false }
    private let counts = Mutex(Counts())

    init(_ plan: Plan) { self.plan = plan }

    var snapshotsYielded: Int { counts.withLock { $0.yielded } }
    var capExhausted: Bool { counts.withLock { $0.capExhausted } }

    func snapshots(for prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch plan {
                case .snapshots(let all):
                    for s in all {
                        continuation.yield(s)
                        counts.withLock { $0.yielded += 1 }
                    }
                    continuation.finish()
                case .snapshotsThenThrow(let all, let error):
                    for s in all {
                        continuation.yield(s)
                        counts.withLock { $0.yielded += 1 }
                    }
                    continuation.finish(throwing: error)
                case .spinsUntilCancelled:
                    for _ in 0..<100_000 {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        await Task.yield()
                    }
                    counts.withLock { $0.capExhausted = true }
                    continuation.finish()
                case .defiantSnapshots(let all):
                    // No cancellation check anywhere — deliberately.
                    for s in all {
                        continuation.yield(s)
                        counts.withLock { $0.yielded += 1 }
                        await Task.yield()
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - the kit, applied to the REAL generator over scripted streams

@Suite(.timeLimit(.minutes(1)))
struct AppleReplyGeneratorTests {

    static func generator(_ plan: ScriptedSnapshotSource.Plan,
                          refusal: String = "I can't answer that.") -> AppleReplyGenerator {
        AppleReplyGenerator(source: ScriptedSnapshotSource(plan), spokenRefusal: refusal)
    }

    static func forged(_ text: String = "forged") -> LanguageModelSession.GenerationError.Context {
        .init(debugDescription: text)
    }

    // MARK: the kit's five promises

    @Test("cumulative snapshots become suffix tokens, then finished, once")
    func tokensThenFinished() async throws {
        try await ReplyConformanceKit.verifyTokensThenExactlyOneTerminal(
            Self.generator(.snapshots(["The", "The capital", "The capital of France."])),
            expecting: ["The", " capital", " of France."])
    }

    @Test("cancel ends the stream without a terminal")
    func cancelNoTerminal() async throws {
        try await ReplyConformanceKit.verifyCancelEndsWithoutATerminal(
            Self.generator(.spinsUntilCancelled))
    }

    @Test("nothing survives the cancel — a defiant source reaches nobody")
    func nothingSurvivesCancel() async throws {
        try await ReplyConformanceKit.verifyNothingSurvivesTheCancel(
            Self.generator(.defiantSnapshots(["ghost", "ghost words"])))
    }

    @Test("openReply hands off — generation never blocks the opener")
    func openHandsOff() async throws {
        let source = ScriptedSnapshotSource(.spinsUntilCancelled)
        let generator = AppleReplyGenerator(source: source)
        try await ReplyConformanceKit.verifyOpenReplyHandsOff(generator)
        #expect(!source.capExhausted, "the cancel must arrive, not be waited out")
    }

    @Test("a throwing source is one .failed, terminal")
    func failureIsOneTerminal() async throws {
        try await ReplyConformanceKit.verifyFailureIsOneTerminal(
            Self.generator(.snapshotsThenThrow(["part"],
                NSError(domain: "test", code: 1))))
    }

    // MARK: the tripwire, end to end (D-058)

    @Test("a REVISING stream: true tokens out, then one honest failure, never the rewrite")
    func revisionFiresTheTripwire() async throws {
        let run = try await Self.generator(
            .snapshots(["The answer is yes", "The answer is no, actually"])
        ).openReply(to: "anything")
        let updates = await ReplyConformanceKit.drain(run)

        #expect(updates.first == .token("The answer is yes"),
                "text that extended truthfully was true when emitted — it flows")
        guard case .failed(let reason)? = updates.last else {
            Issue.record("the tripwire must end the run with .failed, got \(updates)")
            return
        }
        #expect(reason.contains("revised"), "the failure names the crime")
        #expect(!updates.contains(.token("The answer is no, actually")),
                "the rewrite must never reach a mouth")
        #expect(ReplyConformanceKit.terminals(in: updates).count == 1)
    }

    @Test("an unchanged snapshot says nothing — no empty tokens")
    func unchangedSnapshotsAreSilent() async throws {
        try await ReplyConformanceKit.verifyTokensThenExactlyOneTerminal(
            Self.generator(.snapshots(["Same", "Same", "Same but longer"])),
            expecting: ["Same", " but longer"])
    }

    // MARK: AC-114 — the nine cases, FORGED (Context has a public init)

    @Test("a guardrail violation is SPOKEN, and the turn completes (F-4 = A)")
    func guardrailIsSpoken() async throws {
        let run = try await Self.generator(
            .snapshotsThenThrow([], LanguageModelSession.GenerationError
                .guardrailViolation(Self.forged())),
            refusal: "I can't help with that.")
            .openReply(to: "something the model declines")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("I can't help with that."), .finished],
                "a refusal is an ordinary outcome — silence would look like a bug")
    }

    @Test("a model refusal is SPOKEN the same way (F-4 = A)")
    func refusalIsSpoken() async throws {
        let run = try await Self.generator(
            .snapshotsThenThrow([], LanguageModelSession.GenerationError
                .refusal(.init(transcriptEntries: []), Self.forged())))
            .openReply(to: "declined")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("I can't answer that."), .finished])
    }

    @Test("the context window overflowing is a named failure")
    func contextWindowFails() async throws {
        let run = try await Self.generator(
            .snapshotsThenThrow(["partial"], LanguageModelSession.GenerationError
                .exceededContextWindowSize(Self.forged())))
            .openReply(to: "too long a conversation")
        let updates = await ReplyConformanceKit.drain(run)
        guard case .failed(let reason)? = updates.last else {
            Issue.record("expected .failed, got \(updates)"); return
        }
        #expect(reason.contains("context window"))
    }

    @Test("assets unavailable names the Simulator lesson — availability lied")
    func assetsUnavailableFails() async throws {
        let run = try await Self.generator(
            .snapshotsThenThrow([], LanguageModelSession.GenerationError
                .assetsUnavailable(Self.forged())))
            .openReply(to: "anything")
        let updates = await ReplyConformanceKit.drain(run)
        guard case .failed(let reason)? = updates.last else {
            Issue.record("expected .failed, got \(updates)"); return
        }
        #expect(reason.contains("availability said yes"))
    }

    @Test("rate limiting, concurrency, decoding, guides: each one honest .failed")
    func remainingCasesFail() async throws {
        let errors: [LanguageModelSession.GenerationError] = [
            .rateLimited(Self.forged()),
            .concurrentRequests(Self.forged()),
            .decodingFailure(Self.forged()),
            .unsupportedGuide(Self.forged()),
            .unsupportedLanguageOrLocale(Self.forged()),
        ]
        for error in errors {
            let run = try await Self.generator(.snapshotsThenThrow([], error))
                .openReply(to: "anything")
            let updates = await ReplyConformanceKit.drain(run)
            let ends = ReplyConformanceKit.terminals(in: updates)
            #expect(ends.count == 1, "exactly one terminal for \(error)")
            if case .failed = ends.first {} else {
                Issue.record("expected .failed for \(error), got \(updates)")
            }
        }
    }

    // MARK: AC-110 — unavailability refuses at the door

    /// Gated INVERSELY to the model-gated suites: it runs only where the
    /// model is NOT available (this Mac today, most CI runners), and
    /// skips honestly on a machine where it is — the same honesty, the
    /// other way round.
    @Test("openReply throws the honest reason when the model is unavailable")
    func unavailableRefusesAtTheDoor() async throws {
        guard AppleReplyGenerator.availability != nil else { return }
        await #expect(throws: AppleReplyGenerator.Unavailable.self) {
            _ = try await AppleReplyGenerator().openReply(to: "anything")
        }
    }
}
