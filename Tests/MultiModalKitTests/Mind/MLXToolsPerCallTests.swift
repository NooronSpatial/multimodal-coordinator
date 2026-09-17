import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// TOOLS PER CALL, ON THE MLX RUN WITHOUT A MODEL (4z, SPEC §193/5,
// AC-275; D-110 F-2 = A) — and the two guards around the door.
//
// The scripted mind's rows are `ToolsPerCallTests`; these are the MLX
// run's, on `ScriptedTokenSource`, which plays the model. ONE rule for
// this mind: the call's table when the call carries one — even `.empty`
// — and the source's own otherwise. The source renders the resolved
// table into its prompt and the run executes from the same one; here
// the run's half is proved, and the rule itself is read off the source.
// The person's "yes" (F-10 B-ii) rides on the same options and is read
// at the door, so its row is here too.
//
// The source's round counter runs ACROSS replies, so a script of four
// rounds is two replies of two rounds each: a call round, then the
// round the model speaks once it has read the answer.

@Suite("4z · tools per call on the MLX run — the call's table wins, the source's is the default (AC-275)",
       .timeLimit(.minutes(1)))
struct MLXToolsPerCallTests {
    private static let value = ToolParameter(name: "value", description: "the reading",
                                             kind: .number, isRequired: true)
    private static let call = ToolCallRequest(name: "log_reading", arguments: ["value": 83.5])

    /// Two replies' worth of rounds: each reply asks for the tool, then
    /// says "done" once it has read whatever came back.
    private static func twoReplies() -> ScriptedTokenSource.Plan {
        .rounds([
            [.toolCall(call), .stopped(.complete)], [.token("done"), .stopped(.complete)],
            [.toolCall(call), .stopped(.complete)], [.token("done"), .stopped(.complete)]
        ])
    }

    /// What reply N's model was TOLD: round 1 of reply N is index 2N + 1,
    /// and what it was asked AFTER is the exchange the run fed back.
    private static func told(_ source: ScriptedTokenSource, reply: Int) -> String? {
        let asked = source.askedAfter
        guard asked.indices.contains(2 * reply + 1) else { return nil }
        return asked[2 * reply + 1].first?.answer
    }

    @Test("a source with no table and a call carrying one: the tool runs; the next call without it cannot")
    func theCallsTableIsUsedThenGone() async throws {
        let tool = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("logged"))
        let source = ScriptedTokenSource(Self.twoReplies())
        let mind = MLXReplyGenerator(source: source)

        let with = try await mind.openReply(to: ReplyContext(
            transcript: "log eighty-three and a half",
            options: GenerationOptions(tools: ToolTable([tool.tool]))))
        #expect(await ReplyConformanceKit.drain(with) == [.token("done"), .finished(.complete)])
        #expect(tool.calls == [["value": 83.5]], "the run called the call's tool with the typed argument")
        #expect(Self.told(source, reply: 0) == "logged")

        let without = try await mind.openReply(to: "and now?")
        #expect(await ReplyConformanceKit.drain(without) == [.token("done"), .finished(.complete)])
        #expect(Self.told(source, reply: 1) == "no tool named 'log_reading'",
                "with no table on the call, the source's own (empty) table answers")
        #expect(tool.calls.count == 1, "the tool ran exactly once")
    }

    @Test("a source built WITH a table and a call carrying .empty: no tool that turn; the next call has it back")
    func emptyOnTheCallMeansNone() async throws {
        let own = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("logged"))
        let source = ScriptedTokenSource(Self.twoReplies(), tools: ToolTable([own.tool]))
        let mind = MLXReplyGenerator(source: source)

        let none = try await mind.openReply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: .empty)))
        _ = await ReplyConformanceKit.drain(none)
        #expect(Self.told(source, reply: 0) == "no tool named 'log_reading'")
        #expect(own.calls.isEmpty, "the source's own tool was hidden for that call")

        let back = try await mind.openReply(to: "q")
        _ = await ReplyConformanceKit.drain(back)
        #expect(Self.told(source, reply: 1) == "logged", "nil on the next call: the source's table is back")
        #expect(own.calls.count == 1)
    }

    @Test("a call's table REPLACES the source's for that call; it does not add to it")
    func theCallsTableReplaces() async throws {
        let own = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("own"))
        let perCall = ScriptedTool(name: "set_timer", plan: .answers("set"))
        let source = ScriptedTokenSource(Self.twoReplies(), tools: ToolTable([own.tool]))
        let mind = MLXReplyGenerator(source: source)
        let reply = try await mind.openReply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: ToolTable([perCall.tool]))))
        _ = await ReplyConformanceKit.drain(reply)
        #expect(Self.told(source, reply: 0) == "no tool named 'log_reading'",
                "the source's own tool is not visible on a call that brought its own table")
        #expect(own.calls.isEmpty)
        #expect(perCall.calls.isEmpty, "and the call's tool was simply not asked for")
    }

    /// The rule itself, read off the source — what the prompt renders
    /// from and what the run executes from are one table.
    @Test("the resolution rule: nil is the source's own, a table is that table, .empty is none — and renders nil")
    func theResolutionRule() {
        let own = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers(""))
        let other = ScriptedTool(name: "set_timer", plan: .answers(""))
        let source = ScriptedTokenSource(Self.twoReplies(), tools: ToolTable([own.tool]))
        #expect(source.tools(for: ReplyContext(transcript: "q")) == ToolTable([own.tool]))
        #expect(source.tools(for: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: ToolTable([other.tool])))) == ToolTable([other.tool]))
        let none = source.tools(for: ReplyContext(transcript: "q", options: GenerationOptions(tools: .empty)))
        #expect(none == .empty)
        #expect(none.toolSpecs == nil, "no specs reach the vendor: the plain prompt of 4r (AC-272)")
        // And with nothing on either side, `.empty` — AC-272's run half.
        let bare = ScriptedTokenSource(Self.twoReplies())
        #expect(bare.tools(for: ReplyContext(transcript: "q")) == .empty)
    }

    // MARK: - the person's yes travels with the call (F-10 B-ii, AC-279 on this run)

    @Test("a flagged tool is refused until the call's options name it; then its body runs once")
    func theConfirmedSetTravelsWithTheCall() async throws {
        let write = ScriptedTool(name: "log_reading", parameters: [Self.value],
                                 requiresConfirmation: true, plan: .answers("logged"))
        let source = ScriptedTokenSource(Self.twoReplies(), tools: ToolTable([write.tool]))
        let mind = MLXReplyGenerator(source: source)

        let asked = try await mind.openReply(to: "log eighty-three and a half")
        _ = await ReplyConformanceKit.drain(asked)
        #expect(Self.told(source, reply: 0)
                == "tool 'log_reading' needs the person's confirmation: "
                + "ask them, and call it again once they have said yes")
        #expect(write.calls.isEmpty, "the body did not run on the model's word alone")

        let yes = try await mind.openReply(to: ReplyContext(
            transcript: "yes", options: GenerationOptions(confirmedTools: ["log_reading"])))
        _ = await ReplyConformanceKit.drain(yes)
        #expect(Self.told(source, reply: 1) == "logged")
        #expect(write.calls == [["value": 83.5]], "the yes on the call's options let the body run, once")
    }

    // MARK: - the ticket, re-checked BEFORE the door (the reentrancy law's first half)

    /// `aBargeDuringTheCallDropsTheAnswer` (MLXToolRunTests) pins the
    /// check AFTER the door. This pins the one BEFORE it: the round has
    /// ended with a call remembered, the run is retired before the arm
    /// runs, and the tool's body is never entered — a dead run starts no
    /// tool it can never use. Deterministic: the call is scripted BEFORE
    /// the token the test waits for, so the run has remembered it by the
    /// time the token is heard; the source then holds until the cancel.
    @Test("a run retired after the round ended never knocks the door: the body does not run")
    func aRetiredRunStartsNoTool() async throws {
        let tool = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("logged"))
        let source = ScriptedTokenSource(.eventsThenHold([.toolCall(Self.call), .token("Let me log that. ")]),
                                         tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")
        let facts = Facts()
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 1"), "the call was remembered before this token was spoken")
        await run.cancel()
        let updates = try await Wait4y.settled(story)
        #expect(updates == [.token("Let me log that. ")], "no terminal after a cancel")
        #expect(await Wait4y.fact { await (run as? MLXReplyRun)?.awaitWorkerEnd() },
                "the worker has decided: only now is 'never entered' a fact")
        #expect(tool.calls.isEmpty, "the door was not knocked by a dead run")
        #expect(source.askedAfter.count == 1, "no round 1")
    }
}
