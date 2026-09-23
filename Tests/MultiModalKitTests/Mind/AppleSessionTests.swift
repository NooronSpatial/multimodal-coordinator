// AC-303 / AC-304 (5b, SPEC §210): one session for many turns — the
// instructions, the tool schemas and the past are prefilled ONCE, and
// every later turn sends the model only its new words.
//
// Every row drives `FakeSessionMaker` (…+Fake.swift): the Apple model
// reports `modelNotReady` on the machine these were written on, and a
// count of sessions MADE is the count of full prefills paid.

import Testing
@testable import MultiModalKit

@Suite("AC-303/304 · one session for many turns", .timeLimit(.minutes(1)), .serialized)
struct AppleSessionTests {

    /// Turns the way the coordinator runs them: each turn is handed the
    /// turns before it AS THE MEMORY WRITES THEM — the real
    /// `ConversationMemory`, with its bounds wide open so nothing is
    /// dropped (the bound's own rows are AC-308's).
    @available(macOS 26.0, iOS 26.0, *)
    static func talk(to generator: AppleReplyGenerator, turns: Int) async throws {
        var memory = ConversationMemory(maxTurns: 64, maxCharacters: 64_000)
        for number in 1...turns {
            let said = "question \(number)"
            let reply = try await generator.reply(to: ReplyContext(transcript: said, history: memory.turns))
            memory.record(ConversationTurn(said: said, replied: reply.text))
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
        try await Self.talk(to: generator, turns: 10)
        #expect(maker.made.count == 1, "one full prefill for the conversation, not one per turn")
    }

    @Test("turn ten sends the model its new words and nothing else (AC-303)")
    func turnTenIsTheUtteranceOnly() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: maker,
                                                thermal: StillThermometer())
        try await Self.talk(to: generator, turns: 10)
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
        try await Self.talk(to: generator, turns: 10)
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
}
