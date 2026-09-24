// AC-303 / AC-304 (5b, SPEC §210): one session for many turns — the
// instructions, the tool schemas and the past are prefilled ONCE, and
// every later turn sends the model only its new words. With them, the two
// guards the keeper's rule is not correct without: a cut answer ends a
// session's use (D-117 F-10 A, AC-306's core) and a call that shows the
// model something else never uses the conversation's session (AC-309).
//
// Every row drives `FakeSessionMaker` (…+Fake.swift): the Apple model
// reports `modelNotReady` on the machine these were written on, and a
// count of sessions MADE is the count of full prefills paid.

import FoundationModels
import Synchronization
import Testing
@testable import MultiModalKit

@Suite("AC-303/304/306/309 · one session for many turns", .timeLimit(.minutes(1)), .serialized)
struct AppleSessionTests {

    /// A conversation the way the coordinator runs one: each turn is
    /// handed the turns before it AS THE MEMORY WRITES THEM — the real
    /// `ConversationMemory`, with its bounds wide open so nothing is
    /// dropped (the bound's own rows are AC-308's).
    struct Talk {
        var memory = ConversationMemory(maxTurns: 64, maxCharacters: 64_000)

        @available(macOS 26.0, iOS 26.0, *)
        mutating func turn(_ said: String, with generator: AppleReplyGenerator,
                           options: MultiModalKit.GenerationOptions = MultiModalKit.GenerationOptions()) async throws {
            let reply = try await generator.reply(
                to: ReplyContext(transcript: said, history: memory.turns, options: options))
            memory.record(ConversationTurn(said: said, replied: reply.text))
        }

        @available(macOS 26.0, iOS 26.0, *)
        mutating func turns(_ count: Int, with generator: AppleReplyGenerator) async throws {
            for number in 1...count { try await turn("question \(number)", with: generator) }
        }
    }

    static let logWeight = ToolTable([ReplyTool(
        name: "log_weight", description: "records today's weight",
        parameters: [ToolParameter(name: "kg", description: "the weight in kilograms",
                                   kind: .number, isRequired: true)],
        requiresConfirmation: false) { _ in "Logged." }])

    // MARK: - AC-303

    @Test("ten turns, one session (AC-303)")
    func tenTurnsOneSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                                thermal: StillThermometer())
        var talk = Talk()
        try await talk.turns(10, with: generator)
        #expect(maker.made.count == 1, "one full prefill for the conversation, not one per turn")
    }

    @Test("turn ten sends the model its new words and nothing else (AC-303)")
    func turnTenIsTheUtteranceOnly() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                                thermal: StillThermometer())
        var talk = Talk()
        try await talk.turns(10, with: generator)
        #expect(maker.sessions.count == 1)
        let session = try #require(maker.sessions.first)
        #expect(session.asked.map(\.prompt) == (1...10).map { "question \($0)" },
                "each turn asked the SAME session, in order")
        #expect(session.asked.last?.prompt == "question 10",
                "turn ten: its own words — not the instructions, not the schemas, not the nine turns before")
    }

    @Test("ten turns through the coordinator, on the memory it really keeps: one session (AC-303)")
    func tenTurnsThroughTheCoordinator() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let mind = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                           thermal: StillThermometer())
        // Bounds wide open: this row is about the coordinator's memory
        // agreeing with the keeper, and the bound's own rows are AC-308's.
        let coordinator = try TurnCoordinator(
            replyGenerator: mind, synthesizer: InstantMouth(),
            config: .init(maxMemoryTurns: 64, maxMemoryCharacters: 64_000))
        let listener = await coordinator.listen()
        let signals = ToolSpikeTests.Signals()
        let (audio, audioIn) = AsyncStream.makeStream(of: AudioEvent.self)
        let (transcripts, transcriptsIn) = AsyncStream.makeStream(of: TranscriptEvent.self)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await coordinator.run(audio: audio, transcripts: transcripts) }
            group.addTask {
                for await event in listener.events { signals.send(ToolSpikeTests.name(of: event)) }
            }
            for number in 0..<10 {
                let frames = number * 96_000
                audioIn.yield(.speechStarted(utterance: number, at: TurnCoordinatorTests.t(frames)))
                transcriptsIn.yield(.final("question \(number)", utterance: number,
                                           at: TurnCoordinatorTests.t(frames + 960)))
                #expect(await signals.heard("completed:\(number)"), "turn \(number) answered and spoken")
            }
            audioIn.finish()
            transcriptsIn.finish()
            await coordinator.stop()
        }

        #expect(maker.made.count == 1,
                "the memory the coordinator really keeps lets the session continue")
        #expect(maker.sessions.first?.asked.map(\.prompt) == (0..<10).map { "question \($0)" })
    }

    // MARK: - AC-304

    @Test("the instructions and the tools are given once, at the session's birth (AC-304)")
    func instructionsAndToolsGivenOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", tools: Self.logWeight,
                                                sessions: maker, thermal: StillThermometer())
        var talk = Talk()
        try await talk.turns(10, with: generator)
        #expect(maker.made == [FakeSessionMaker.Made(instructions: "speak briefly",
                                                     tools: Self.logWeight, seed: [])],
                "born once, with the instructions, the table, and no past yet")
        // The table still travels with each answer — for its BODIES, so a
        // table rebuilt per call runs that call's closures. What the model
        // is shown was given once: the session never received another
        // declaration, because it has no door for one.
        #expect(maker.sessions.first?.asked.count == 10)
        #expect(maker.sessions.first?.asked.allSatisfy { $0.tools == Self.logWeight } == true)
    }

    /// The demo's shape (`ThoughtWitness`): the generator is built with NO
    /// table and every call carries the same one on its options. The
    /// session's identity is what it was BORN with, compared by value — so
    /// a table that rides on every call is not "another table" every call.
    @Test("the same table on every call keeps one session (AC-304, the demo's shape)")
    func sameCallTableKeepsTheSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                                thermal: StillThermometer())
        var talk = Talk()
        for number in 1...3 {
            try await talk.turn("question \(number)", with: generator,
                                options: MultiModalKit.GenerationOptions(tools: Self.logWeight))
        }
        #expect(maker.made.count == 1)
        #expect(maker.made.first?.tools == Self.logWeight, "born with the call's table")
    }

    /// A yes is bound to the call that carries it (4z, D-110 F-10 B-ii).
    /// When a session lived for one reply, an adapter that captured the
    /// yes at birth captured THAT reply's; a session kept for the
    /// conversation keeps its adapters, so they must read the yes of the
    /// answer in progress. The adapter here is made ONCE, as a kept
    /// session's are, and asked twice.
    @Test("a tool made once for the session honours each answer's own yes (4z F-10 B-ii, kept by 5b)")
    func theYesIsPerAnswer() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let runs = Mutex(0)
        let deleteMeal = ReplyTool(name: "delete_meal", description: "deletes today's last meal",
                                   parameters: [], requiresConfirmation: true) { _ in
            runs.withLock { $0 += 1 }
            return "Deleted."
        }
        let table = ToolTable([deleteMeal])
        let route = ToolRoute(table)
        let adapter = try AppleToolAdapter(deleteMeal, route: route)
        let noArguments = try GeneratedContent(json: "{}")

        route.set(table, confirmed: ["delete_meal"])   // answer 1: the person said yes
        let first = try await adapter.call(arguments: noArguments)
        route.set(table, confirmed: [])                // answer 2: no yes on this call
        let second = try await adapter.call(arguments: noArguments)

        #expect(first == "Deleted.")
        #expect(second == ToolCallFailure(tool: "delete_meal", reason: .needsConfirmation).description,
                "answer one's yes did not carry into answer two")
        #expect(runs.withLock { $0 } == 1, "the body ran once — on the call that carried the yes")
    }

    // MARK: - the guard on a cut answer (D-117 F-10 A, AC-306's core)

    /// The hardest case for the rule: a barge BEFORE the first word. The
    /// memory refuses a turn with no answer, so the history the next turn
    /// brings is EXACTLY what the cut session was seeded with — equality
    /// alone would continue it, on a vendor session whose cancelled answer
    /// may still hold the question. Only the guard tells them apart.
    @Test("a session whose answer was cut is never asked again, even when the history still matches (AC-306)")
    func aCutAnswerEndsTheSessionsUse() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let signals = ToolSpikeTests.Signals()
        let maker = FakeSessionMaker(signals: signals) { prompt in
            prompt == "question 1" ? .holdsUntilCut : .answers(["Answer to \(prompt)."])
        }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())

        let cut = try await generator.openReply(to: ReplyContext(transcript: "question 1"))
        #expect(await signals.heard("asked:question 1"), "the answer is under way when it is cut")
        await cut.cancel()

        // The memory refused the half turn, so the history is still empty,
        // and the ledger kept the words: the next thought carries both.
        _ = try await generator.reply(to: ReplyContext(transcript: "question 1 question 2"))

        #expect(maker.made.count == 2, "a new session, seeded from the memory")
        #expect(maker.made.last?.seed.isEmpty == true, "seeded with the memory: empty, the cut turn refused")
        #expect(maker.sessions.first?.asked.map(\.prompt) == ["question 1"],
                "the cut session answered nothing more")
    }

    // MARK: - AC-309

    @Test("a call with other instructions gets a session of its own; the conversation's is not disturbed (AC-309)")
    func otherInstructionsAreAnsweredAside() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                                thermal: StillThermometer())
        var talk = Talk()
        try await talk.turns(2, with: generator)
        let before = talk.memory.turns

        _ = try await generator.reply(to: ReplyContext(
            transcript: "summarise today", history: before,
            options: MultiModalKit.GenerationOptions(instructions: "reply as JSON")))
        try await talk.turn("question 3", with: generator)

        #expect(maker.made.map(\.instructions) == ["speak briefly", "reply as JSON"])
        #expect(maker.made.last?.seed == before, "the aside is seeded with the history it brought (F-2 A)")
        #expect(maker.sessions.first?.asked.map(\.prompt) == ["question 1", "question 2", "question 3"],
                "the conversation went on in its own session, undisturbed")
        #expect(maker.sessions.last?.asked.map(\.prompt) == ["summarise today"])
    }

    @Test("a call with another table gets a session of its own; the conversation's is not disturbed (AC-309)")
    func anotherTableIsAnsweredAside() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", tools: Self.logWeight,
                                                sessions: maker, thermal: StillThermometer())
        var talk = Talk()
        try await talk.turns(2, with: generator)

        _ = try await generator.reply(to: ReplyContext(
            transcript: "no tools for this one", history: talk.memory.turns,
            options: MultiModalKit.GenerationOptions(tools: .empty)))
        try await talk.turn("question 3", with: generator)

        #expect(maker.made.map(\.tools) == [Self.logWeight, .empty])
        #expect(maker.sessions.first?.asked.map(\.prompt) == ["question 1", "question 2", "question 3"])
    }
}
