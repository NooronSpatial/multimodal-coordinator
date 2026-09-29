// 5b piece R: THE REPLY RETRY (SPEC §213; D-121, D-122 F-15…F-20 A; built
// before PROBE-R by D-123 — the phone confirms or reopens F-18 A).
//
//     ask 1 ── log_weight(84) RUNS ✓ ── the vendor fails: no reason, no word yet
//        │
//        └─▶ ask 2 — ONE retry (F-15 A), a FRESH session from the same
//            history, the same words (F-18 A)
//              log_weight(84) again ─▶ answered from its RECORD: the body
//                                      does not run (F-16 A)
//              "Logged 84 kg."      ─▶ the person hears ONE answer
//
// Every row drives `FakeSessionMaker`. The tool's body COUNTS its runs,
// because R-1's hard rule — a write that ran never runs again — is a
// number, not a promise.

import FoundationModels
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit

@Suite("AC-317…AC-321 · the reply retry", .timeLimit(.minutes(1)), .serialized)
struct AppleRetryTests {

    /// Counts a tool body's runs.
    final class Ledger: Sendable {
        private let runs = Mutex(0)
        var bodyRuns: Int { runs.withLock { $0 } }
        func ran() { runs.withLock { $0 += 1 } }
    }

    /// The diet app's write, counted.
    static func logWeight(_ ledger: Ledger) -> ToolTable {
        ToolTable([ReplyTool(
            name: "log_weight", description: "records today's weight",
            parameters: [ToolParameter(name: "kg", description: "the weight in kilograms",
                                       kind: .number, isRequired: true)],
            requiresConfirmation: false) { _ in
                ledger.ran()
                return "Logged 84 kg."
            }])
    }

    static let call = FakeSession.Call(tool: "log_weight", arguments: ["kg": 84])

    /// The diet app's failure as this library meets it: an error that is
    /// neither a `GenerationError` nor a `ToolCallError`.
    static let vendorWords = "tokengeneration Code=10"
    static var unnamed: any Error { FakeSessionFailure(words: vendorWords) }

    /// A script that answers each ASK in turn — the first ask, then the
    /// retry — whatever the words; once the plans run out, every ask is
    /// answered plainly.
    static func asks(_ plans: [FakeSession.Plan]) -> @Sendable (String) -> FakeSession.Plan {
        let next = Mutex(0)
        return { prompt in
            let index = next.withLock { index in
                defer { index += 1 }
                return index
            }
            return index < plans.count ? plans[index] : .answers(["Answer to \(prompt)."])
        }
    }

    /// Ask 1 fails after its tool; the retry repeats the call and answers.
    static let failThenAnswer: [FakeSession.Plan] = [
        .callsThen([call], .fails(unnamed)),
        .callsThen([call], .answers(["Logged", "Logged 84 kg."]))
    ]

    // MARK: - AC-317: one reply, one body run

    @Test("one retry, one reply, one body run (AC-317)")
    func oneRetryOneReplyOneBodyRun() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let ledger = Ledger()
        let maker = FakeSessionMaker(script: Self.asks(Self.failThenAnswer))
        let generator = try AppleReplyGenerator(tools: Self.logWeight(ledger), sessions: maker,
                                                thermal: StillThermometer())
        let reply = try await generator.reply(to: ReplyContext(transcript: "log 84 kilos"))

        #expect(reply.text == "Logged 84 kg.", "ONE answer — the retry's")
        #expect(ledger.bodyRuns == 1, "the write ran once; the retry's repeat was answered from its record")
        #expect(reply.tools.count == 1, "one act, reported once")
        #expect(maker.made.count == 2, "the retry ran in a fresh session (F-18 A)")
        #expect(maker.sessions.map { $0.asked.map(\.prompt) } == [["log 84 kilos"], ["log 84 kilos"]],
                "the same words, asked again")
        #expect(maker.made.map(\.seed) == [[], []], "seeded from the same history")
    }

    @Test("through the coordinator: the turn completes, and the retried session carries the conversation (AC-317)")
    func theTurnCompletes() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let ledger = Ledger()
        let maker = FakeSessionMaker(script: Self.asks(Self.failThenAnswer))
        let rig = try await CoordinatorRig(mind: try AppleReplyGenerator(
            tools: Self.logWeight(ledger), sessions: maker, thermal: StillThermometer()))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.say("log 84 kilos", utterance: 0), "one answer spoken; the turn completed")
            #expect(await rig.say("and a coffee", utterance: 1))
            await rig.end()
        }
        #expect(ledger.bodyRuns == 1)
        #expect(maker.made.count == 2,
                "the retry repeated every call, so its session holds what the memory holds: it continues")
    }

    // MARK: - AC-318: no third try

    @Test("two failures: the named failure, once — no third try (AC-318)")
    func twoFailuresEndOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let ledger = Ledger()
        let log = HealthLog()
        let maker = FakeSessionMaker(script: Self.asks([
            .callsThen([Self.call], .fails(Self.unnamed)),
            .callsThen([Self.call], .fails(Self.unnamed))]))
        let generator = try AppleReplyGenerator(tools: Self.logWeight(ledger), sessions: maker,
                                                thermal: StillThermometer(), diagnostics: log.diagnostics)
        let run = try await generator.openReply(to: "log 84 kilos")
        let updates = await ReplyConformanceKit.drain(run)
        await log.close()

        let failures = updates.filter { if case .failed = $0 { true } else { false } }
        #expect(failures == [.failed(.unexplained(Self.vendorWords))], "the named failure, exactly once")
        #expect(maker.made.count == 2, "one retry, never a third ask (F-15 A)")
        #expect(ledger.bodyRuns == 1, "the write still ran once")
        #expect(log.retries.count == 1, "one retry, one event")
    }

    // MARK: - AC-319: what is never retried

    @Test("no retry when no tool ran: nothing was saved, the person can say it again (AC-319)")
    func noToolNoRetry() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .callsThen([], .fails(Self.unnamed)) }
        let generator = try AppleReplyGenerator(tools: Self.logWeight(Ledger()), sessions: maker,
                                                thermal: StillThermometer())
        await #expect(throws: ReplyFailure.unexplained(Self.vendorWords)) {
            _ = try await generator.reply(to: ReplyContext(transcript: "hello"))
        }
        #expect(maker.made.count == 1)
    }

    @Test("no retry once a word was said: a second answer would be a stutter (AC-319, F-19 A)")
    func noRetryAfterAWord() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let ledger = Ledger()
        let maker = FakeSessionMaker { _ in .callsThen([Self.call], .snapshotThenFails("Logged", Self.unnamed)) }
        let generator = try AppleReplyGenerator(tools: Self.logWeight(ledger), sessions: maker,
                                                thermal: StillThermometer())
        await #expect(throws: ReplyFailure.unexplained(Self.vendorWords)) {
            _ = try await generator.reply(to: ReplyContext(transcript: "log 84 kilos"))
        }
        #expect(maker.made.count == 1)
        #expect(ledger.bodyRuns == 1)
    }

    /// Every vendor case with a name — each one ends the turn as it always
    /// did, and none is asked again. A refusal is how a reply ENDS (D-104).
    @Test("no retry for a failure with a name (AC-319)",
          arguments: ["context", "assets", "language", "rate", "concurrent", "guardrail", "refusal"])
    func namedFailuresAreNotRetried(_ which: String) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let error = Self.named(which)
        let maker = FakeSessionMaker { _ in .callsThen([Self.call], .fails(error)) }
        let generator = try AppleReplyGenerator(tools: Self.logWeight(Ledger()), sessions: maker,
                                                thermal: StillThermometer())
        let run = try await generator.openReply(to: "log 84 kilos")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(maker.made.count == 1, "\(which): asked once")
        #expect(!updates.contains { if case .failed(.unexplained) = $0 { true } else { false } },
                "\(which) keeps its name")
    }

    @available(macOS 26.0, iOS 26.0, *)
    static func named(_ which: String) -> LanguageModelSession.GenerationError {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "forged")
        switch which {
        case "context": return .exceededContextWindowSize(context)
        case "assets": return .assetsUnavailable(context)
        case "language": return .unsupportedLanguageOrLocale(context)
        case "rate": return .rateLimited(context)
        case "concurrent": return .concurrentRequests(context)
        case "guardrail": return .guardrailViolation(context)
        default: return .refusal(.init(transcriptEntries: []), context)
        }
    }

    @Test("a failure at the door makes no session, so nothing to retry (AC-319: .tooHot)")
    func aDoorFailureIsNotRetried() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker(script: Self.asks(Self.failThenAnswer))
        let generator = try AppleReplyGenerator(tools: Self.logWeight(Ledger()), sessions: maker,
                                                thermal: ScriptedThermalProvider(initial: .critical))
        await #expect(throws: ReplyFailure.tooHot(.critical)) {
            _ = try await generator.openReply(to: "log 84 kilos")
        }
        #expect(maker.made.isEmpty)
    }

    // MARK: - AC-320: a barge during the retry

    /// The retry repeats the call — answered from its record — and then
    /// holds; the next onset barges it (no barge window: an onset while
    /// the mind is thinking IS a barge).
    @Test("a barge during the retry cancels it; the write stands; nothing runs twice (AC-320)")
    func aBargeDuringTheRetry() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let ledger = Ledger()
        let log = HealthLog()
        let asked = ToolSpikeTests.Signals()
        let maker = FakeSessionMaker(signals: asked, script: Self.asks([
            .callsThen([Self.call], .fails(Self.unnamed)),
            .callsThen([Self.call], .holdsUntilCut)]))
        let rig = try await CoordinatorRig(mind: try AppleReplyGenerator(
            tools: Self.logWeight(ledger), sessions: maker, thermal: StillThermometer(),
            diagnostics: log.diagnostics))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            rig.begin("log 84 kilos", utterance: 0)
            #expect(await asked.heard("holding:log 84 kilos"), "the retry is running, its repeat answered")
            rig.onset(utterance: 1)
            #expect(await rig.signals.heard("barged:0"))
            rig.final("question 1", utterance: 1)
            #expect(await rig.signals.heard("completed:1"))
            await rig.end()
        }
        await log.close()

        #expect(ledger.bodyRuns == 1, "the write stands, and ran once")
        #expect(maker.made.count == 3, "ask 1, the retry, then the next turn's own session")
        #expect(maker.sessions.dropFirst().first?.asked.map(\.prompt) == ["log 84 kilos"],
                "the cut retry answered nothing more")
        #expect(maker.made.last?.seed.first?.tools.count == 1, "the act that happened is remembered")
        #expect(log.seeds.last == .mindSessionSeeded(.lastAnswerUnfinished, turns: 1))
    }

    // MARK: - AC-321: the retry is seen

    @Test("one retry, one health event naming it, beside the fresh session's birth (AC-321)")
    func theRetryIsSeen() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker(script: Self.asks(Self.failThenAnswer))
        let generator = try AppleReplyGenerator(tools: Self.logWeight(Ledger()), sessions: maker,
                                                thermal: StillThermometer(), diagnostics: log.diagnostics)
        _ = try await generator.reply(to: ReplyContext(transcript: "log 84 kilos"))
        await log.close()

        #expect(log.retries == [.mindReplyRetried(after: Self.vendorWords)])
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.lastAnswerFailed(Self.vendorWords), turns: 0)])
    }
}
