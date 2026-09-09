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

    // MARK: - D-104 (F-7 = C): a refusal is SPOKEN, and it is how the reply ENDS

    /// THE RULING (D-104, SPEC §178 F-7 = C). Two signed things could not
    /// both be true: D-057 F-4 = A says a refusal is SPOKEN and the turn
    /// completes, because silence makes a refusal look like a bug; §175/3
    /// listed `.refused` as a `ReplyFailure`, which is a turn that ends
    /// with nothing said. C dissolves it — the sentence is still spoken
    /// (voice is untouched) and the stream ends `.finished(.refused)`, so
    /// a TEXT caller learns why the reply ended and can count it.
    ///
    /// This test pins both halves at once, for both vendor cases: the
    /// person hears the sentence AND the stop reason names the reason.
    @Test("a refusal is spoken and ends .finished(.refused) — D-104")
    func refusalIsSpokenAndEndsRefused() async throws {
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
            #expect(updates == [.token("I can't help with that."), .finished(.refused)],
                    "spoken, then .refused — for \(error)")
        }
    }

    /// The WHOLE POINT of C for the text caller (Aura's slice 1): a
    /// refusal is an outcome it can count, not an error it must catch.
    /// `reply(to:)` returns — it does not throw — and the `Reply` carries
    /// both the sentence the person heard and the reason it ended.
    @Test("reply(to:) RETURNS a refusal as Reply(text:, stop: .refused) — D-104")
    func wholeReplyCarriesTheRefusal() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let mind = AppleReplyGenerator(
            source: ScriptedSnapshotSource(.snapshotsThenThrow(
                [], LanguageModelSession.GenerationError
                    .refusal(.init(transcriptEntries: []), Self.forged()))),
            spokenRefusal: "I can't help with that.")
        let reply = try await mind.reply(to: ReplyContext(transcript: "declined"))
        #expect(reply == Reply(text: "I can't help with that.", stop: .refused),
                "a refusal is an outcome, not a thrown error")
    }

    /// WHAT A REFUSAL AFTER PARTIAL TEXT LOOKS LIKE, pinned because the
    /// review found it undocumented and a caller will meet it.
    ///
    /// The model can start answering and be stopped mid-sentence. Those
    /// tokens were already spoken — the person HEARD them — so they stay
    /// in the reply, and the app's refusal sentence follows with no
    /// separator, exactly as the ear received it. For a text caller the
    /// glued string is not a problem to solve here but a reason to READ
    /// THE STOP REASON: `.refused` means the text is an abandoned answer
    /// plus an apology, and Aura's validator will reject it as the
    /// half-written JSON it is. Inventing a separator would be this
    /// library writing the app's words (D-027); dropping the partial text
    /// would make the transcript disagree with what was said aloud.
    @Test("a refusal after partial text keeps what was already spoken — D-104")
    func refusalAfterPartialTextKeepsIt() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let mind = AppleReplyGenerator(
            source: ScriptedSnapshotSource(.snapshotsThenThrow(
                ["Sure", "Sure I can"], LanguageModelSession.GenerationError
                    .refusal(.init(transcriptEntries: []), Self.forged()))),
            spokenRefusal: "I can't help with that.")
        let reply = try await mind.reply(to: ReplyContext(transcript: "declined"))
        #expect(reply == Reply(text: "Sure I canI can't help with that.", stop: .refused))
    }

    /// AN EMPTY REFUSAL SENTENCE IS SILENCE, and silence must not be
    /// dressed as speech. An app may configure `spokenRefusal: ""` — its
    /// right — but the stream must then carry NO token at all, or a
    /// caller would read a spoken refusal that nobody heard. Every other
    /// emit path in the generator already drops empty pieces; this one
    /// did not until the 4v review found it.
    @Test("an empty refusal sentence yields no token, only the ending — D-104")
    func emptyRefusalYieldsNoToken() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let run = try await AppleReplyGenerator(
            source: ScriptedSnapshotSource(.snapshotsThenThrow(
                [], LanguageModelSession.GenerationError
                    .refusal(.init(transcriptEntries: []), Self.forged()))),
            spokenRefusal: "")
            .openReply(to: "declined")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.finished(.refused)], "no empty token was spoken")
    }
}
