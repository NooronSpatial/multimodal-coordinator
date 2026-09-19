// TOOLS PER CALL, ON THE SCRIPTED MIND (4z, SPEC §193/5, AC-275; D-110
// F-2 = A — 4w's closing fork, ruled on §67's numbers).
//
// A generator built with a table keeps it as its DEFAULT; a call whose
// `GenerationOptions.tools` is set uses THAT table for that call and
// nothing else — `nil` is "the generator's", a table replaces it, and
// `.empty` is "none this turn" even on a generator that holds some. The
// app pays the prompt's tool cost only on the turns that may use one.
// The scripted mind's rows are here; the MLX run's and the Apple
// session's are those minds' own pieces of 4z.

import MultiModalKit
import MultiModalKitTesting
import Testing

@Suite("4z · tools per call — the call's table wins, the generator's is the default (AC-275)",
       .timeLimit(.minutes(1)))
struct ToolsPerCallTests {
    private static let answer = "Today is a 40 minute easy run."
    private static let day = ToolParameter(name: "day", description: "which day", kind: .string, isRequired: false)

    @Test("a generator with no tools and a call carrying a table: the tool is called; the next call without one cannot")
    func theCallsTableIsUsedThenGone() async throws {
        let tool = ScriptedTool(name: "session", parameters: [Self.day], plan: .answers(Self.answer))
        let script = ToolScript(name: "session", arguments: ["day": "today"],
                                onFailure: .speaks(["I could not."]))
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script), .callsTool(script)], tools: .empty)

        let with = try await generator.reply(to: ReplyContext(
            transcript: "what is today's session?",
            options: GenerationOptions(tools: ToolTable([tool.tool]))))
        #expect(with.text == Self.answer)
        #expect(generator.record(ofReply: 0)?.toolCalls.map(\.outcome) == [.answered(Self.answer)])

        let without = try await generator.reply(to: ReplyContext(transcript: "and now?"))
        #expect(without.text == "I could not.", "the model was shown no tool: the call is refused as unknown")
        #expect(generator.record(ofReply: 1)?.toolCalls.map(\.outcome)
                == [.failed(ToolCallFailure(tool: "session", reason: .unknownTool))],
                "with no table on the call, the generator's own (empty) table answers")
        #expect(tool.calls == [["day": "today"]], "the tool ran exactly once")
    }

    @Test("a generator built WITH a table and a call carrying .empty: no tool this turn")
    func emptyOnTheCallMeansNone() async throws {
        let own = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let script = ToolScript(name: "session", onFailure: .speaks(["no session"]))
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script), .callsTool(script)],
                                               tools: ToolTable([own.tool]))

        let none = try await generator.reply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: .empty)))
        #expect(none.text == "no session")
        #expect(own.calls.isEmpty, "the generator's own tool was hidden for that call")

        let back = try await generator.reply(to: ReplyContext(transcript: "q"))
        #expect(back.text == Self.answer, "nil on the next call: the generator's table is back")
        #expect(own.calls.count == 1)
    }

    @Test("a call's table REPLACES the generator's for that call; it does not add to it")
    func theCallsTableReplaces() async throws {
        let own = ScriptedTool(name: "session", plan: .answers("own"))
        let perCall = ScriptedTool(name: "weather", plan: .answers("sunny"))
        let script = ToolScript(name: "session", onFailure: .speaks(["no session"]))
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script)], tools: ToolTable([own.tool]))
        let reply = try await generator.reply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: ToolTable([perCall.tool]))))
        #expect(reply.text == "no session",
                "the generator's own tool is not visible on a call that brought its own table")
        #expect(own.calls.isEmpty)
        #expect(perCall.calls.isEmpty, "and the call's tool was simply not asked for")
    }

    @Test("the options carry the table and the yes, and stay Equatable (AC-282's shape)")
    func optionsCarryTheTable() {
        let tool = ScriptedTool(name: "session", plan: .answers(""))
        let options = GenerationOptions(tools: ToolTable([tool.tool]), confirmedTools: ["session"])
        #expect(options.tools == ToolTable([tool.tool]))
        #expect(options.confirmedTools == ["session"])
        #expect(GenerationOptions().tools == nil, "the default is the generator's own — the pre-4z call")
        #expect(GenerationOptions().confirmedTools.isEmpty, "and nothing is confirmed by default")
    }
}
