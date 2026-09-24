// 5b piece 2: A TOOL CALL IS A TOOL CALL (AC-305, AC-311; D-116 F-3 A,
// D-117 F-8 A, D-119 F-14 A, D-120).
//
//     the model calls log_weight ─▶ the adapter REPORTS the use
//         ─▶ .toolRan on the reply stream ─▶ the coordinator keeps it on the turn
//         ─▶ the memory holds it ─▶ a re-seed replays it as a CALL and an OUTPUT
//
// Before 5b the last arrow wrote the tool's sentence as the assistant's
// prose, and the phone heard "Logged 12 kg" from a turn in which no tool
// ran (SPEC §207). Every row here drives `FakeSessionMaker`, the adapter,
// or a vendor session that is BUILT and never asked — the Apple model
// reports `modelNotReady` on the machine these were written on.

import FoundationModels
import Synchronization
import Testing
@testable import MultiModalKit

@Suite("AC-305/311 · a tool call is a tool call", .timeLimit(.minutes(1)), .serialized)
struct AppleSessionToolTests {

    /// `log_weight` answered — the use every row replays or carries.
    static let logged = ConversationMemoryTests.logged

    /// The tool itself, declared as the app would.
    static let logWeight = ReplyTool(
        name: "log_weight", description: "records today's weight",
        parameters: [ToolParameter(name: "kg", description: "the weight in kilograms",
                                   kind: .number, isRequired: true)],
        requiresConfirmation: false) { _ in "Logged 84 kg." }

    static let turnWithTool = ConversationTurn(said: "log 84 kilos", replied: "Done — 84 kg.",
                                               tools: [logged])

    // MARK: - the replay (AC-305)

    /// Each entry of a transcript, as one word a row can compare.
    @available(macOS 26.0, iOS 26.0, *)
    static func kinds<S: Sequence>(_ entries: S) -> [String] where S.Element == Transcript.Entry {
        entries.map { entry in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            case .response: "response"
            @unknown default: "unknown"
            }
        }
    }

    /// The words of a list of segments.
    @available(macOS 26.0, iOS 26.0, *)
    static func words(_ segments: [Transcript.Segment]) -> String {
        segments.map { segment in
            if case .text(let text) = segment { text.content } else { "" }
        }.joined()
    }

    @Test("a remembered tool call is replayed as a CALL and an OUTPUT, not as prose (AC-305)")
    func aToolIsReplayedTyped() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let entries = AppleSession.entries(instructions: nil, seed: [Self.turnWithTool])
        #expect(Self.kinds(entries) == ["prompt", "toolCalls", "toolOutput", "response"])

        guard entries.count == 4,
              case .toolCalls(let calls) = entries[1],
              case .toolOutput(let output) = entries[2],
              case .response(let response) = entries[3] else { return }
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.toolName == "log_weight")
        #expect(ToolArguments(call.arguments) == Self.logged.arguments,
                "the model is shown its own call, arguments and all")
        #expect(output.toolName == "log_weight")
        #expect(Self.words(output.segments) == "Logged 84 kg.", "what the model was told, as an OUTPUT")
        #expect(output.id == call.id, "the output answers the call it belongs to")
        #expect(Self.words(response.segments) == "Done — 84 kg.", "then the mind's own words, as before")
    }

    @Test("a turn with no tool replays exactly as before (AC-305's other half)")
    func aPlainTurnReplaysAsBefore() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let plain = ConversationTurn(said: "what is Swift?", replied: "A language.")
        let cut = ConversationTurn(said: "tell me more", replied: "It was made", interrupted: true)
        let entries = AppleSession.entries(instructions: "speak briefly", seed: [plain, cut])
        #expect(Self.kinds(entries) == ["instructions", "prompt", "response", "prompt", "response"])
        guard case .response(let last) = entries.last else { return }
        #expect(Self.words(last.segments) == "It was made…", "a cut reply still carries its mark")
    }

    /// D-119 F-14 A: the act is the answer. The replay is the prompt, the
    /// call and its output — and a response with no words, the shape the
    /// vendor writes when the model says nothing after a tool.
    @Test("a turn where a tool ran and the mind said nothing replays the act (D-119)")
    func aSilentActIsReplayed() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let silent = ConversationTurn(said: "log 84 kilos", replied: "", tools: [Self.logged])
        let entries = AppleSession.entries(instructions: nil, seed: [silent])
        #expect(Self.kinds(entries) == ["prompt", "toolCalls", "toolOutput", "response"])
    }

    /// The vendor fact under the replay: a session BORN with typed tool
    /// entries holds them. Built, never asked — no model needed.
    @Test("a vendor session born with a typed tool call holds it (the vendor fact under AC-305)")
    func theVendorKeepsTypedEntries() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let session = try AppleSession(instructions: "speak briefly", tools: ToolTable([Self.logWeight]),
                                       seed: [Self.turnWithTool])
        #expect(Self.kinds(session.session.transcript)
                == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
    }

    // MARK: - the record's road (D-117 F-8 A)

    @Test("the adapter reports each use to the answer in progress (D-117 F-8 A)")
    func theAdapterReportsTheUse() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let heard = Mutex<[ToolUse]>([])
        let table = ToolTable([Self.logWeight])
        let route = ToolRoute(table)
        route.set(table, confirmed: []) { use in heard.withLock { $0.append(use) } }
        let adapter = try AppleToolAdapter(Self.logWeight, route: route)

        let words = try await adapter.call(arguments: try GeneratedContent(json: #"{"kg": 84}"#))

        #expect(words == "Logged 84 kg.")
        #expect(heard.withLock { $0 } == [ToolUse(name: "log_weight", arguments: ["kg": 84],
                                                  outcome: ToolCallOutcome(result: .success("Logged 84 kg.")))])
    }

    @Test("a refused call is reported too: the model was told something (D-117 F-8 A)")
    func aRefusalIsAUse() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let deleteMeal = ReplyTool(name: "delete_meal", description: "deletes the last meal",
                                   parameters: [], requiresConfirmation: true) { _ in "Deleted." }
        let heard = Mutex<[ToolUse]>([])
        let table = ToolTable([deleteMeal])
        let route = ToolRoute(table)
        route.set(table, confirmed: []) { use in heard.withLock { $0.append(use) } }
        let adapter = try AppleToolAdapter(deleteMeal, route: route)

        _ = try await adapter.call(arguments: try GeneratedContent(json: "{}"))

        let refusal = ToolCallFailure(tool: "delete_meal", reason: .needsConfirmation)
        #expect(heard.withLock { $0 } == [ToolUse(name: "delete_meal", arguments: .empty,
                                                  outcome: ToolCallOutcome(result: .failure(refusal)))])
    }

    @Test("the Apple mind sends .toolRan on the reply stream when a tool ran (D-117 F-8 A)")
    func theStreamCarriesTheRecord() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .steps([.toolRan(Self.logged), .snapshot("Logged 84 kg.")]) }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        let run = try await generator.openReply(to: ReplyContext(transcript: "log 84 kilos"))
        var updates: [ReplyUpdate] = []
        for await update in run.updates { updates.append(update) }
        #expect(updates == [.toolRan(Self.logged), .token("Logged 84 kg."), .finished(.unreported)])
    }

    @Test("a text caller finds the tools on Reply (D-117 F-8 A)")
    func aTextCallerReadsTheTools() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .steps([.toolRan(Self.logged), .snapshot("Logged 84 kg.")]) }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        let reply = try await generator.reply(to: ReplyContext(transcript: "log 84 kilos"))
        #expect(reply == Reply(text: "Logged 84 kg.", stop: .unreported, tools: [Self.logged]))
    }

    // MARK: - the coordinator keeps it (AC-311)

    @Test("the coordinator keeps what ran on the turn it belongs to (AC-311)")
    func theCoordinatorKeepsTheTools() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { prompt in
            prompt == "log 84 kilos"
                ? .steps([.toolRan(Self.logged), .snapshot("Logged 84 kg.")])
                : .answers(["You are welcome."])
        }
        let rig = try await CoordinatorRig(
            mind: try AppleReplyGenerator(sessions: maker, thermal: StillThermometer()))
        var memory: [ConversationTurn] = []
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.say("log 84 kilos", utterance: 0))
            #expect(await rig.say("thanks", utterance: 1))
            memory = await rig.coordinator.currentMemory   // before end(): stop() forgets
            await rig.end()
        }
        #expect(memory == [
            ConversationTurn(said: "log 84 kilos", replied: "Logged 84 kg.", tools: [Self.logged]),
            ConversationTurn(said: "thanks", replied: "You are welcome.")
        ], "the tool is on ITS turn, and a turn with none carries none")
    }

    @Test("a turn where a tool ran and the mind said nothing is remembered through the coordinator (D-119)")
    func theCoordinatorKeepsASilentAct() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .steps([.toolRan(Self.logged)]) }
        let rig = try await CoordinatorRig(
            mind: try AppleReplyGenerator(sessions: maker, thermal: StillThermometer()))
        var memory: [ConversationTurn] = []
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.say("log 84 kilos", utterance: 0), "zero words still completes the turn")
            memory = await rig.coordinator.currentMemory
            await rig.end()
        }
        #expect(memory == [ConversationTurn(said: "log 84 kilos", replied: "", tools: [Self.logged])])
    }

    /// The keeper writes a finished answer the way the memory does —
    /// tools included — or every turn that used one would look like a
    /// changed history and re-seed.
    @Test("ten turns that each use a tool, through the coordinator: still one session (AC-303 with tools)")
    func toolTurnsKeepTheSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .steps([.toolRan(Self.logged), .snapshot("Logged.")]) }
        let rig = try await CoordinatorRig(
            mind: try AppleReplyGenerator(sessions: maker, thermal: StillThermometer()))
        var remembered = 0
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            for number in 0..<10 {
                #expect(await rig.say("log \(80 + number) kilos", utterance: number))
            }
            remembered = await rig.coordinator.currentMemory.filter { $0.tools == [Self.logged] }.count
            await rig.end()
        }
        #expect(remembered == 10, "every turn kept its tool")
        #expect(maker.made.count == 1, "and the session was made once")
    }
}
