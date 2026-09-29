// 5c: THE TYPED TURN FAILURE (R-3; SPEC §215–§220, D-128 F-23 A).
//
//     a reply fails ──▶ ReplyFailure ──▶ TurnFailure.generationFailed(<the same value>)
//                                         on the turn event AND on the health road,
//                                         mid-stream and at the open
//
// Before 5c both roads carried the failure's WORDS (AC-242), so an app in
// a conversation could not switch on `.unexplained` — and both of the diet
// app's field failures happened in a conversation.

import MultiModalKitTesting
import Testing
@testable import MultiModalKit

@Suite("AC-324…AC-329 · a turn's failure is typed", .timeLimit(.minutes(1)), .serialized)
struct TypedTurnFailureTests {

    /// A mind that fails at the open with whatever it is given — the road
    /// a caller's own generator can take.
    struct FailingAtTheOpen: ReplyGenerating {
        let error: any Error
        func openReply(to context: ReplyContext) async throws -> any ReplyRun { throw error }
    }

    struct CallersOwnError: Error, CustomStringConvertible {
        var description: String { "the caller's own words" }
    }

    /// One utterance through the coordinator: the turn's failure as the
    /// turn event carried it, and every dead turn on the health road.
    static func failure(of mind: any ReplyGenerating) async throws -> (turn: TurnFailure?, health: [HealthEvent]) {
        let log = HealthLog()
        let rig = try await CoordinatorRig(mind: mind, diagnostics: log.diagnostics)
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            rig.begin("log 84 kilos", utterance: 0)
            #expect(await rig.signals.heard("failed:0"), "the turn failed")
            await rig.end()
        }
        await log.close()
        return (rig.events.failures.first, log.turnFailures)
    }

    // MARK: - AC-324, AC-326, AC-328: mid-stream

    @Test("mid-stream: the turn carries the reply's failure, typed, and the health road the same (AC-324, AC-326)")
    func midStreamIsTyped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let mind = try AppleReplyGenerator(sessions: FakeSessionMaker { _ in .fails("tokengeneration Code=10") },
                                           thermal: StillThermometer())
        let (turn, health) = try await Self.failure(of: mind)
        let expected = ReplyFailure.unexplained("tokengeneration Code=10")

        #expect(turn == .generationFailed(expected), "the app can switch on .unexplained in a conversation")
        #expect(health == [.turnFailed(turn: 0, failure: .generationFailed(expected))],
                "the health road carries the same typed value")
        // AC-328: the words a screen showed before 5c are the payload's own.
        #expect(expected.description
                == "the model failed without a reason this library can name: tokengeneration Code=10")
    }

    // MARK: - AC-325: at the open

    @Test("at the open: a ReplyFailure thrown by the mind is the turn's failure, typed (AC-325)")
    func atTheOpenIsTyped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let mind = try AppleReplyGenerator(sessions: FakeSessionMaker(),
                                           thermal: ScriptedThermalProvider(initial: .critical))
        let (turn, health) = try await Self.failure(of: mind)

        #expect(turn == .generationFailed(.tooHot(.critical)))
        #expect(health == [.turnFailed(turn: 0, failure: .generationFailed(.tooHot(.critical)))])
    }

    // MARK: - AC-327, AC-328: what is not a ReplyFailure

    @Test("a caller's own error at the open keeps its words, as .engine (AC-327, AC-328)")
    func aForeignErrorKeepsItsWords() async throws {
        let (turn, _) = try await Self.failure(of: FailingAtTheOpen(error: CallersOwnError()))
        #expect(turn == .generationFailed(.engine("the caller's own words")),
                "the words the string carried before 5c; .unexplained stays the vendor's")
    }

    @Test("a TurnFailure thrown at the open passes through unchanged (AC-327)")
    func aTurnFailurePassesThrough() async throws {
        let (turn, _) = try await Self.failure(of: FailingAtTheOpen(error: TurnFailure.generationFailed(.busy)))
        #expect(turn == .generationFailed(.busy), "not wrapped a second time")
    }

    // MARK: - AC-329: the diet app's case, end to end

    /// The Apple mind runs its tool, fails with no reason, asks again once
    /// (§213), and the retry fails too — the turn a person hears nothing
    /// from, which the app wants to speak its own sentence for.
    @Test("the unnamed failure, after its retry, reaches the conversation typed (AC-329)")
    func theUnnamedFailureReachesTalk() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let mind = try AppleReplyGenerator(
            tools: AppleRetryTests.logWeight(AppleRetryTests.Ledger()),
            sessions: FakeSessionMaker(script: AppleRetryTests.asks([
                .callsThen([AppleRetryTests.call], .fails(AppleRetryTests.unnamed)),
                .callsThen([AppleRetryTests.call], .fails(AppleRetryTests.unnamed))])),
            thermal: StillThermometer())
        let (turn, health) = try await Self.failure(of: mind)
        let expected = TurnFailure.generationFailed(.unexplained(AppleRetryTests.vendorWords))

        #expect(turn == expected)
        #expect(health == [.turnFailed(turn: 0, failure: expected)])
    }
}
