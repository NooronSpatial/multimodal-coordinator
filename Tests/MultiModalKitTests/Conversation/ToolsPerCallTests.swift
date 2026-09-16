// TOOLS PER CALL (4z, SPEC §193/5, AC-272; D-108 F-2 = A — 4w's closing
// fork, ruled on its numbers).
//
// A generator built with a table keeps it as its DEFAULT; a call whose
// `GenerationOptions.tools` is set uses THAT table for that call and
// nothing else. The app pays the prompt's tool cost only on the turns
// that may use one. Three minds, one rule, proved without a model: the
// scripted mind through the seam, the MLX run through its scripted
// token source, the Apple mind through the session it builds.

import Foundation
import FoundationModels
import MultiModalKitTesting
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

@Suite("4z · tools per call — the call's table wins, the generator's is the default (AC-272)",
       .timeLimit(.minutes(1)))
struct ToolsPerCallTests {
    private static let answer = "Today is a 40 minute easy run."

    // MARK: the scripted mind

    @Test("the scripted mind: a generator with no tools calls the call's table; the next call without one cannot")
    func scriptedMindUsesTheCallsTable() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let script = ToolScript(name: "session", arguments: ["day": "today"],
                                onFailure: .speaks(["I could not."]))
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script), .callsTool(script)], tools: .empty)

        let with = try await generator.reply(to: ReplyContext(
            transcript: "what is today's session?",
            options: GenerationOptions(tools: ToolTable([tool.tool]))))
        #expect(with.text == Self.answer)
        #expect(generator.record(ofReply: 0)?.toolCalls.map(\.outcome) == [.answered(Self.answer)])

        let without = try await generator.reply(to: ReplyContext(transcript: "and now?"))
        #expect(without.text == "I could not.")
        #expect(generator.record(ofReply: 1)?.toolCalls.map(\.outcome)
                == [.failed(ToolCallFailure(tool: "session", reason: .unknownTool))],
                "with no table on the call, the generator's own (empty) table answers")
        #expect(tool.calls == [["day": "today"]], "the tool ran exactly once")
    }

    @Test("the scripted mind: a call's table REPLACES the generator's for that call — it does not add")
    func theCallsTableReplaces() async throws {
        let own = ScriptedTool(name: "session", plan: .answers("own"))
        let perCall = ScriptedTool(name: "weather", plan: .answers("sunny"))
        let script = ToolScript(name: "session", arguments: .none, onFailure: .speaks(["no session"]))
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script)], tools: ToolTable([own.tool]))
        let reply = try await generator.reply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: ToolTable([perCall.tool]))))
        #expect(reply.text == "no session",
                "the generator's own tool is not visible on a call that brought its own table")
        #expect(own.calls.isEmpty)
    }

    // MARK: the MLX run

    @Test("the MLX run: the source rendered no tools, the call carried one, the run executes it from the call's table")
    func mlxRunUsesTheCallsTable() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let source = ScriptedTokenSource(.rounds([
            [.token("Let me check. "),
             .toolCall(ToolCallRequest(name: "session", arguments: ["day": "today"])),
             .stopped(.complete)],
            [.token("It is a 40 minute easy run."), .stopped(.complete)]
        ]), tools: .empty)
        let run = try await MLXReplyGenerator(source: source).openReply(to: ReplyContext(
            transcript: "What is today's session?",
            options: GenerationOptions(tools: ToolTable([tool.tool]))))
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("Let me check. "),
                            .token("It is a 40 minute easy run."),
                            .finished(.complete)])
        #expect(tool.calls == [["day": "today"]])
        #expect(source.askedAfter.last?.first?.answer == Self.answer, "the answer went back to the model")
    }

    @Test("the MLX source renders the call's table into the prompt, and its own when the call brings none")
    func mlxSourceRendersTheCallsTable() throws {
        let own = ReplyTool(name: "session", description: "reads the session") { _ in "" }
        let perCall = ReplyTool(name: "weather", description: "reads the sky") { _ in "" }
        let mind = MLXTokenSource(model: LocalMindModel(weights: URL(filePath: "/nonexistent")),
                                  instructions: nil, maxTokens: 8, tools: ToolTable([own]))
        let withOwn = mind.tools(for: ReplyContext(transcript: "q"))
        #expect(withOwn.tools.map(\.name) == ["session"])
        let withCall = mind.tools(for: ReplyContext(transcript: "q",
                                                    options: GenerationOptions(tools: ToolTable([perCall]))))
        #expect(withCall.tools.map(\.name) == ["weather"])
        let withEmptyCall = mind.tools(for: ReplyContext(transcript: "q",
                                                         options: GenerationOptions(tools: .empty)))
        #expect(withEmptyCall.isEmpty, "an explicit empty table on the call means NO tools this turn")
    }

    // MARK: the Apple mind

    @Test("the Apple mind: the session a reply is born with carries the call's tools, or the generator's")
    func appleSessionCarriesTheCallsTools() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let own = ReplyTool(name: "session", description: "reads the session") { _ in "" }
        let perCall = ReplyTool(name: "weather", description: "reads the sky") { _ in "" }
        let snapshots = FoundationModelSnapshots(tools: ToolTable([own]))

        func names(_ session: LanguageModelSession) -> [String] {
            session.transcript.compactMap { entry -> [String]? in
                if case .instructions(let found) = entry { return found.toolDefinitions.map(\.name) }
                return nil
            }.first ?? []
        }
        #expect(names(snapshots.session(instructions: "brief", history: [],
                                        tools: snapshots.tools(for: ReplyContext(transcript: "q")))) == ["session"])
        let perCallContext = ReplyContext(transcript: "q", options: GenerationOptions(tools: ToolTable([perCall])))
        #expect(names(snapshots.session(instructions: "brief", history: [],
                                        tools: snapshots.tools(for: perCallContext))) == ["weather"])
    }

    // MARK: the option itself

    @Test("GenerationOptions compares tables by what the model is shown, not by the closures")
    func optionsEquality() {
        let day = ToolParameter(name: "day", description: "which", kind: .string)
        let shown = ReplyTool(name: "session", description: "reads", parameters: [day]) { _ in "one body" }
        let sameShown = ReplyTool(name: "session", description: "reads", parameters: [day]) { _ in "another body" }
        let otherWords = ReplyTool(name: "session", description: "reads more") { _ in "one body" }
        #expect(GenerationOptions(tools: ToolTable([shown])) == GenerationOptions(tools: ToolTable([sameShown])))
        #expect(GenerationOptions(tools: ToolTable([shown])) != GenerationOptions(tools: ToolTable([otherWords])))
        #expect(GenerationOptions() == GenerationOptions(tools: nil))
        #expect(GenerationOptions(tools: .empty) != GenerationOptions(),
                "nil is 'the generator's'; .empty is 'none this call'")
    }
}
