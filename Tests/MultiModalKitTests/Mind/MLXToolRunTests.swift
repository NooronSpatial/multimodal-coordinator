import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE RUN'S ARM, PROVEN WITHOUT A MODEL (4w, AC-222; D-101 F-1 = B,
// F-4 = B).
//
// `ScriptedTokenSource.rounds` plays the model: round 0 says a few
// words and asks for a tool, round 1 says the answer. The run in between
// is the real `MLXReplyRun` — it executes the call through the real
// `ToolTable`, re-checks its own life after the await, feeds the answer
// back as the next round's exchanges, and speaks what comes next. What
// the model was TOLD is read from `askedAfter`, which is how F-4 = B's
// words are pinned: the failure sentence goes to the model, not to the
// coordinator.
//
// Every wait here is an event or a bounded drain; nothing sleeps.

@Suite("AC-222 · the MLX run executes a call itself and asks again with the answer",
       .timeLimit(.minutes(1)))
struct MLXToolRunTests {
    private static let answer = "Today is a 40 minute easy run, readiness 71."
    private static let call = ToolCallRequest(name: "session", arguments: ["day": "today"])

    /// Round 0 ends with a call; round 1 is what the model says once it
    /// has read the answer.
    private static func twoRounds(calling name: String = "session") -> ScriptedTokenSource.Plan {
        .rounds([
            [.token("Let me check. "),
             .toolCall(ToolCallRequest(name: name, arguments: ["day": "today"])),
             .stopped(.complete)],
            [.token("It is a 40 minute easy run."), .stopped(.complete)]
        ])
    }

    @Test("a scripted call: the table is called with the flattened arguments, the answer follows, one terminal")
    func theCallIsMadeAndTheReplyContinues() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let source = ScriptedTokenSource(Self.twoRounds(), tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "What is today's session?")
        let updates = await ReplyConformanceKit.drain(run)

        #expect(updates == [.token("Let me check. "),
                            .token("It is a 40 minute easy run."),
                            .finished(.complete)],
                "the words before the call, then the words after the answer, then ONE terminal")
        #expect(tool.calls == [["day": "today"]], "the run called the tool with the arguments the model gave")
        #expect(source.askedAfter == [[], [ToolExchange(request: Self.call, answer: Self.answer)]],
                "round 1 was asked AFTER the exchange — the answer went back to the model")
    }

    /// A tool round's own `.stopped` is the model ending its turn to
    /// ask. It is NOT the reply's end, and the coordinator must never
    /// hear it as one.
    @Test("a tool round's stop is not the reply's terminal — only the last round's is")
    func theToolRoundsStopIsNotTheTerminal() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let source = ScriptedTokenSource(.rounds([
            [.toolCall(Self.call), .stopped(.complete)],
            [.token("done"), .stopped(.tokenBudget)]
        ]), tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("done"), .finished(.tokenBudget)],
                "exactly one terminal, and it is the LAST round's reason")
    }

    // MARK: - F-4 = B: the model is told, in words, and recovers

    @Test("a name no tool has is answered to the MODEL as 'no tool named …' and the reply completes")
    func anUnknownNameIsAnsweredToTheModel() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let source = ScriptedTokenSource(Self.twoRounds(calling: "weather"), tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")
        let updates = await ReplyConformanceKit.drain(run)

        #expect(updates.last == .finished(.complete), "not .failed — that was the rejected option A")
        #expect(tool.calls.isEmpty, "the only tool was never called: the name did not match")
        let told = source.askedAfter.last?.first
        #expect(told == ToolExchange(
            request: ToolCallRequest(name: "weather", arguments: ["day": "today"]),
            answer: "no tool named 'weather'"),
                "the model read ToolCallFailure's sentence as the tool's response")
    }

    @Test("a tool that throws is answered to the MODEL as 'tool … failed: …' and the reply completes")
    func aThrowingToolIsAnsweredToTheModel() async throws {
        let tool = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let source = ScriptedTokenSource(Self.twoRounds(), tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")
        let updates = await ReplyConformanceKit.drain(run)

        #expect(updates.last == .finished(.complete))
        #expect(tool.calls.count == 1)
        #expect(source.askedAfter.last?.first?.answer == "tool 'session' failed: the stub is offline")
    }

    // MARK: - the cap

    /// One script that always calls is a model that calls forever. The
    /// run answers `ToolRounds.cap` rounds and refuses the next, typed —
    /// it never spins.
    @Test("a model that calls forever is stopped after ToolRounds.cap rounds with a typed failure")
    func theRoundCapEndsARunawayReply() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let source = ScriptedTokenSource(
            .rounds([[.token("again "), .toolCall(Self.call), .stopped(.complete)]]),
            tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")
        let updates = await ReplyConformanceKit.drain(run)

        #expect(ToolRounds.cap == 4, "the cap is stated in the doc; a change must move this row too")
        #expect(tool.calls.count == ToolRounds.cap, "exactly cap rounds were answered")
        #expect(source.askedAfter.count == ToolRounds.cap + 1,
                "the round after the cap was opened, asked for a tool again, and was refused")
        #expect(updates.last == .failed(ToolRounds.exceeded))
        #expect(updates.last == .failed(.engine("the model asked for a tool in more than 4 rounds of one reply")),
                "the words are pinned: a caller reads them, and the contract milestone may type them")
        #expect(updates.filter { $0 == .token("again ") }.count == ToolRounds.cap + 1,
                "every round's words were spoken before the refusal — tokens then one terminal")
    }

    // MARK: - the reentrancy law: a barge during the call

    /// AC-226 on this seam: the tool is slow, the reply is cancelled
    /// while the call is in flight, and the answer — when it finally
    /// comes — goes NOWHERE. No second round is asked for, no token is
    /// spoken, no terminal is reported. The wait for "entered" is an
    /// EVENT (the tool signals it), never a delay.
    @Test("a cancel while the tool is in flight: the answer is dropped, no round 1, no terminal")
    func aBargeDuringTheCallDropsTheAnswer() async throws {
        let (entered, signalEntered) = AsyncStream.makeStream(of: Void.self)
        let tool = ScriptedTool(name: "session",
                                plan: .waitsForRelease(then: .answers(Self.answer))) { _ in
            signalEntered.yield(())
        }
        let source = ScriptedTokenSource(Self.twoRounds(), tools: ToolTable([tool.tool]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: "q")

        let seen = Mutex<[ReplyUpdate]>([])
        let ended = Mutex(false)
        let collector = Task {
            for await update in run.updates { seen.withLock { $0.append(update) } }
            ended.withLock { $0 = true }
        }
        defer { collector.cancel() }

        // The FACT the test waits on: the run has entered the tool.
        for await _ in entered { break }
        await run.cancel()
        tool.release()

        #expect(await ReplyConformanceKit.until { ended.withLock { $0 } },
                "a cancelled reply's stream must END")
        // The worker has DECIDED: the answer came back, the run read its
        // own retirement, and returned. Only now is "no round 1" final.
        await (run as? MLXReplyRun)?.awaitWorkerEnd()
        let updates = seen.withLock { $0 }
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty,
                "a cancelled reply never claims completion, whatever the tool answers later")
        #expect(source.askedAfter.count == 1,
                "no round 1: the answer arrived after the barge and was fed back to nobody")
        #expect(!updates.contains(.token("It is a 40 minute easy run.")))
    }
}
