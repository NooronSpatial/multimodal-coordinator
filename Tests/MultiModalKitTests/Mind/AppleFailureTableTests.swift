import Foundation
import FoundationModels
import Testing
@testable import MultiModalKit

/// AC-236, the Apple half (SPEC §175/3, D-103 F-3 = A): every case of
/// the vendor's `GenerationError` lands on ONE row of the failure table,
/// and every row is `Equatable` — so a caller can COUNT, where a string
/// could only be read.
///
/// The errors are FORGED through the scripted seam (`Context` has a
/// public init): a real model cannot be asked to rate-limit itself on
/// cue, and AC-114 already proved the forging works. Every test is
/// runtime-gated on OS 26, as the whole Apple kit is — swift-testing
/// forbids `@available` on a `@Test`.
@Suite("AC-236 · the Apple mind's failures are typed, one row per vendor case",
       .timeLimit(.minutes(1)))
struct AppleFailureTableTests {

    @available(macOS 26.0, iOS 26.0, *)
    static func forged() -> LanguageModelSession.GenerationError.Context {
        .init(debugDescription: "forged")
    }

    /// Drives one forged error through the real generator and returns
    /// the `.failed` payload, or nil when the run did not fail — the
    /// table's whole question, asked once per row.
    @available(macOS 26.0, iOS 26.0, *)
    static func failure(after error: any Error) async throws -> ReplyFailure? {
        let run = try await AppleReplyGenerator(
            source: ScriptedSnapshotSource(.snapshotsThenThrow([], error)))
            .openReply(to: "anything")
        let updates = await ReplyConformanceKit.drain(run)
        guard case .failed(let failure)? = updates.last else { return nil }
        return failure
    }

    // MARK: - the rows

    @Test("rate limiting and a concurrent request are both .busy")
    func rateLimitAndConcurrencyAreBusy() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let limited = try await Self.failure(
            after: LanguageModelSession.GenerationError.rateLimited(Self.forged()))
        let concurrent = try await Self.failure(
            after: LanguageModelSession.GenerationError.concurrentRequests(Self.forged()))
        #expect(limited == .busy, "the system rate-limited generation")
        #expect(concurrent == .busy, "a second request reached one session")
    }

    @Test("a caller can COUNT: two scripted .busy runs are two")
    func twoBusyRunsCountAsTwo() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        var busy = 0
        for error in [LanguageModelSession.GenerationError.rateLimited(Self.forged()),
                      LanguageModelSession.GenerationError.concurrentRequests(Self.forged())] {
            let failure = try await Self.failure(after: error)
            if failure == .busy { busy += 1 }
        }
        #expect(busy == 2, "the count AC-236 asks for — a string could not be counted")
    }

    @Test("an unsupported language is .unsupportedLanguage")
    func unsupportedLanguageIsTyped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let failure = try await Self.failure(
            after: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(Self.forged()))
        #expect(failure == .unsupportedLanguage)
    }

    @Test("the context window overflowing stays .contextWindowExceeded")
    func contextWindowStaysTyped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let failure = try await Self.failure(
            after: LanguageModelSession.GenerationError.exceededContextWindowSize(Self.forged()))
        #expect(failure == .contextWindowExceeded)
    }

    @Test("a decoding failure and an unsupported guide are .engine — the honest rest")
    func decodingAndGuideAreEngine() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        for error in [LanguageModelSession.GenerationError.decodingFailure(Self.forged()),
                      LanguageModelSession.GenerationError.unsupportedGuide(Self.forged())] {
            let failure = try await Self.failure(after: error)
            guard case .engine(let words)? = failure else {
                Issue.record("expected .engine for \(error), got \(String(describing: failure))")
                continue
            }
            #expect(!words.isEmpty, "the words stay for a screen")
        }
    }

    @Test("an error the vendor's enum does not own is .engine with its words")
    func foreignErrorIsEngine() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let failure = try await Self.failure(after: NSError(domain: "test", code: 7))
        guard case .engine(let words)? = failure else {
            Issue.record("expected .engine, got \(String(describing: failure))"); return
        }
        #expect(words.contains("reply generation failed"))
    }

    // MARK: - F-7 pending: a refusal is SPOKEN and the turn ends as today

    /// Until Ryad rules F-7 (SPEC §178), today's behaviour holds
    /// UNCHANGED: the refusal sentence is spoken (D-057 F-4 = A) and the
    /// turn ends `.finished(.unreported)` — exactly what the seam left
    /// at the base. Whether the stop should read `.complete` (F-7 A) or
    /// `.refused` (F-7 C) is the fork's question, so this test pins
    /// today's value and nothing more; the ruling rewrites this line
    /// under its D-entry.
    @Test("a refusal is spoken and ends .finished(.unreported) — F-7 pending, today's value")
    func refusalIsSpokenAndCompletes() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        for error in [LanguageModelSession.GenerationError
                          .guardrailViolation(Self.forged()),
                      LanguageModelSession.GenerationError
                          .refusal(.init(transcriptEntries: []), Self.forged())] {
            let run = try await AppleReplyGenerator(
                source: ScriptedSnapshotSource(.snapshotsThenThrow([], error)),
                spokenRefusal: "I can't help with that.")
                .openReply(to: "declined")
            let updates = await ReplyConformanceKit.drain(run)
            #expect(updates == [.token("I can't help with that."), .finished(.unreported)],
                    "spoken, then today's stop — for \(error)")
        }
    }
}
