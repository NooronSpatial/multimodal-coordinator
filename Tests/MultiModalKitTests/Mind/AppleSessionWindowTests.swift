// 5b piece 3b: THE MEMORY'S BOUND AGAINST A KEPT SESSION (AC-308, amended
// by D-118 F-12 C and D-124 F-22 B).
//
//     the memory (bound 4):             t3 t4 t5 t6    ← the window
//     the kept session holds:   t1 t2   t3 t4 t5 t6    ← more, never less
//                                       └─ the window is its NEWEST turns ─▶ CONTINUE it
//
//     the vendor's wall (context full) BEFORE any word:
//        the session held MORE than the window ─▶ re-seed from the window, ask again once
//        it held just the window              ─▶ the turn fails, as AC-116 does (F-22 B)
//     AFTER a word ─▶ the turn fails; the next turn re-seeds (.contextFull)
//
// Every row drives `FakeSessionMaker`; the health road is read with
// `HealthLog`.

import FoundationModels
import Testing
@testable import MultiModalKit

@Suite("AC-308 · the memory's bound against a kept session", .timeLimit(.minutes(1)), .serialized)
struct AppleSessionWindowTests {

    typealias Talk = AppleSessionTests.Talk

    static func bounded(_ turns: Int) -> Talk {
        Talk(memory: ConversationMemory(maxTurns: turns, maxCharacters: 64_000))
    }

    @available(macOS 26.0, iOS 26.0, *)
    static var wall: LanguageModelSession.GenerationError {
        .exceededContextWindowSize(.init(debugDescription: "forged: 4096 tokens"))
    }

    // MARK: - the window rule (D-118 F-12 C)

    @Test("the session keeps what the window dropped: six turns at a bound of four, one session (AC-308)")
    func theSessionKeepsWhatTheWindowDropped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        var talk = Self.bounded(4)
        try await talk.turns(6, with: generator)
        #expect(talk.memory.count == 4, "the memory kept its bound")
        #expect(maker.made.count == 1,
                "the memory's window is the session's newest turns: continued, never rebuilt at the bound")
    }

    @Test("a re-seed carries the bound, typed: the last four turns with their tools, not the first two (AC-308)")
    func aReseedCarriesTheBound() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let use = ToolUse(name: "log_weight", arguments: ["kg": 84],
                          outcome: ToolCallOutcome(result: .success("Logged.")))
        let maker = FakeSessionMaker { prompt in
            switch prompt {
            case "question 7": .fails("the model fell over")
            case "question 1", "question 5": .steps([.toolRan(use), .snapshot("Done.")])
            default: .answers(["Answer to \(prompt)."])
            }
        }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        var talk = Self.bounded(4)
        try await talk.turns(6, with: generator)
        await #expect(throws: (any Error).self) { try await talk.turn("question 7", with: generator) }
        let window = talk.memory.turns
        try await talk.turn("question 8", with: generator)

        let seed = try #require(maker.made.last?.seed)
        #expect(seed == window, "the re-seed is the memory's window")
        #expect(seed.map(\.said) == ["question 3", "question 4", "question 5", "question 6"],
                "the last four, not the first two")
        #expect(seed[2].tools == [use], "question 5's tool call is still a tool call (AC-305)")
    }

    @Test("memory off re-seeds every turn with no past (AC-308)")
    func memoryOffReseedsEveryTurn() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        var talk = Self.bounded(0)
        try await talk.turns(3, with: generator)
        await log.close()
        #expect(maker.made.map(\.seed) == [[], [], []], "three turns, three sessions, no past in any")
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.memoryChanged, turns: 0),
                              .mindSessionSeeded(.memoryChanged, turns: 0)])
    }

    // MARK: - the wall (D-118 F-12 C, D-124 F-22 B)

    /// A bound of two and three turns on one session: it holds three, the
    /// window two. Turn four meets the wall before any word — after a tool
    /// ran — and is asked again in a session born from the window alone.
    @Test("full before a word, in a session that outgrew the window: re-seeded and asked again once (AC-308)")
    func fullBeforeAWordIsAskedAgain() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let ledger = AppleRetryTests.Ledger()
        let maker = FakeSessionMaker(script: FakeSessionMaker.script("question 4", asks: [
            .callsThen([AppleRetryTests.call], .fails(Self.wall)),
            .callsThen([AppleRetryTests.call], .answers(["Logged 84 kg."]))]))
        let generator = try AppleReplyGenerator(tools: AppleRetryTests.logWeight(ledger), sessions: maker,
                                                thermal: StillThermometer(), diagnostics: log.diagnostics)
        var talk = Self.bounded(2)
        try await talk.turns(3, with: generator)
        let window = talk.memory.turns
        let reply = try await generator.reply(to: ReplyContext(transcript: "question 4", history: window))
        await log.close()

        #expect(reply.text == "Logged 84 kg.", "the person hears one answer")
        #expect(maker.made.count == 2, "one session for turns one to three, one born at the wall")
        #expect(maker.made.last?.seed == window, "re-seeded from the memory's window")
        #expect(ledger.bodyRuns == 1, "the tool that ran before the wall did not run again")
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.contextFull, turns: 2)])
        #expect(log.retries.isEmpty, "the wall is reported by the birth it caused, not as §213's retry")
    }

    @Test("full after a word: the turn fails, and the next turn re-seeds (AC-308)")
    func fullAfterAWordFails() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker(script: FakeSessionMaker.script("question 4", asks: [
            .callsThen([], .snapshotThenFails("Let me", Self.wall))]))
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        var talk = Self.bounded(2)
        try await talk.turns(3, with: generator)
        await #expect(throws: ReplyFailure.contextWindowExceeded) {
            try await talk.turn("question 4", with: generator)
        }
        #expect(maker.made.count == 1, "no second ask once a word was said")
        try await talk.turn("question 5", with: generator)
        await log.close()
        #expect(log.seeds.last == .mindSessionSeeded(.contextFull, turns: 2), "the next turn re-seeds, and says why")
    }

    /// Added at GREEN: a KEPT session can hold exactly the window too
    /// (bound four, two turns). The row above only reaches a fresh one, so
    /// without this nothing tells "held more" from "held as much".
    @Test("full in a kept session that holds just the window: no re-ask (F-22 B)")
    func fullInAKeptSessionHoldingTheWindowIsNotAskedAgain() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker(script: FakeSessionMaker.script("question 3", asks: [
            .callsThen([], .fails(Self.wall))]))
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        var talk = Self.bounded(4)
        try await talk.turns(2, with: generator)
        await #expect(throws: ReplyFailure.contextWindowExceeded) {
            try await talk.turn("question 3", with: generator)
        }
        #expect(maker.made.count == 1, "continued while holding exactly the window: a re-seed would be the same size")
    }

    @Test("full in a session just seeded from the window: no re-ask, the turn fails as AC-116 does (F-22 B)")
    func fullInAFreshSessionIsNotAskedAgain() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker(script: FakeSessionMaker.script("question 1", asks: [
            .callsThen([], .fails(Self.wall))]))
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        var talk = Self.bounded(2)
        await #expect(throws: ReplyFailure.contextWindowExceeded) {
            try await talk.turn("question 1", with: generator)
        }
        #expect(maker.made.count == 1, "the same past and the same question would meet the same wall")
        try await talk.turn("question 2", with: generator)
        await log.close()
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.contextFull, turns: 0)])
    }
}
