import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE REAL DEADLINE (4y, SPEC §187/4, AC-264, D-107 F-4 = A).
//
// Aura's R7: a reply that runs past `GenerationOptions.deadline` ENDS —
// `.finished(.deadline)` with what was said so far, a stop reason like
// `.tokenBudget`, never a failure. Every row here measures the deadline
// on a `ManualClock`: time moves when the test says, the generation is
// a scripted source that never finishes on its own, and every wait is an
// event raced against a sleeping cap. The live half — a real reply cut at
// 200 ms and the memory freed — is `MLXAdmissionLiveTests`.

@Suite("AC-264 · a deadline ends a slow MLX reply .finished(.deadline)", .timeLimit(.minutes(1)))
struct MLXDeadlineTests {

    private static let twoTokens = ["two", " tokens"]

    private func mind(_ plan: ScriptedTokenSource.Plan, clock: ManualClock)
    -> (MLXReplyGenerator, ScriptedTokenSource) {
        let source = ScriptedTokenSource(plan)
        return (MLXReplyGenerator(source: source, clock: clock), source)
    }

    /// THE ROW THE AC NAMES: a generation that never finishes on its own,
    /// a 200 ms deadline on the manual clock, and the ending is
    /// `.finished(.deadline)` carrying the two tokens already spoken.
    @Test("a reply that never finishes ends .finished(.deadline) with the tokens so far when the clock reaches 200 ms")
    func aSlowReplyEndsOnTheDeadlineWithItsPartialText() async throws {
        let clock = ManualClock()
        let (mind, source) = mind(.tokensThenHold(Self.twoTokens), clock: clock)
        let facts = Facts()
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "a long question",
            options: GenerationOptions(deadline: .milliseconds(200))))
        let story = ReplyStory.collect(run, facts: facts)

        #expect(await facts.heard("token 2"), "both tokens are spoken before the clock moves")
        #expect(await Wait4y.parked(clock), "the deadline is asleep on THIS clock, not on wall time")
        // 199 ms is not the deadline: nothing ends.
        await clock.advance(by: .milliseconds(199))
        #expect(!(await facts.heard("ended", within: .milliseconds(100))),
                "one millisecond short of the deadline the reply is still running")
        await clock.advance(by: .milliseconds(1))

        let updates = try await Wait4y.settled(story)
        #expect(updates == [.token("two"), .token(" tokens"), .finished(.deadline)],
                "the partial text, then ONE terminal, the deadline's")
        #expect(await Wait4y.fact { await source.cancellationSeen() },
                "the generation is CANCELLED by the deadline — the optimisation that frees the prefill")
        #expect(clock.sleeperCount == 0, "no sleeper survives the run")
    }

    /// The sleeper is CANCELLED when the reply ends first — never left
    /// parked on the clock. The scripted mind's rule, kept here: a
    /// `ManualClock` with a stray sleeper is a leak a wall clock hides.
    @Test("a reply that ends before its deadline leaves NO sleeper on the clock")
    func aReplyThatEndsFirstLeavesNoSleeper() async throws {
        let clock = ManualClock()
        let (mind, _) = mind(.events([.token("done"), .stopped(.complete)]), clock: clock)
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "a short question",
            options: GenerationOptions(deadline: .seconds(30))))
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("done"), .finished(.complete)],
                "the reply's own ending is the one heard; the deadline never speaks")
        // The worker's end is the fact: the race is over and its loser
        // cancelled. Only then is "no sleeper" a claim and not a hope.
        let worker = try #require(run as? MLXReplyRun)
        #expect(await Wait4y.fact { await worker.awaitWorkerEnd() })
        #expect(clock.sleeperCount == 0, "the deadline's sleeper was cancelled with the race")
        // And a clock that then moves past the deadline wakes nobody.
        await clock.advance(by: .seconds(31))
        #expect(clock.sleeperCount == 0)
    }

    /// NO DEADLINE, NO SLEEPER (AC-265's half on this seam): the voice
    /// path passes none, and the run must add nothing to what ran before
    /// 4y — not even a parked task.
    @Test("with no deadline the run arms nothing on the clock")
    func noDeadlineArmsNothing() async throws {
        let clock = ManualClock()
        let (mind, _) = mind(.tokensThenHold(Self.twoTokens), clock: clock)
        let facts = Facts()
        let run = try await mind.openReply(to: "a question with no deadline")
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 2"))
        #expect(clock.sleeperCount == 0, "nothing sleeps on the clock when no deadline was asked for")
        await run.cancel()
        let updates = try await Wait4y.settled(story)
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty)
    }

    /// A cancel BEFORE the deadline: the stream ends with no terminal (the
    /// cancel contract), and the sleeper goes with the worker.
    @Test("a cancel before the deadline ends with no terminal and no sleeper")
    func aCancelBeforeTheDeadlineLeavesNothing() async throws {
        let clock = ManualClock()
        let (mind, _) = mind(.tokensThenHold(Self.twoTokens), clock: clock)
        let facts = Facts()
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "a question", options: GenerationOptions(deadline: .milliseconds(200))))
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 2"))
        #expect(await Wait4y.parked(clock))
        await run.cancel()
        let updates = try await Wait4y.settled(story)
        #expect(updates == [.token("two"), .token(" tokens")], "no terminal after a cancel")
        let worker = try #require(run as? MLXReplyRun)
        #expect(await Wait4y.fact { await worker.awaitWorkerEnd() })
        #expect(clock.sleeperCount == 0)
        // The deadline arriving AFTER the cancel is not heard either.
        await clock.advance(by: .milliseconds(200))
        #expect(try await Wait4y.settled(story) == [.token("two"), .token(" tokens")])
    }

    /// THE TICKET: a token the source yields AFTER the deadline fired is
    /// provably unable to reach a listener. `gatedDefiance` yields one
    /// token, holds until the test releases it — which the test does only
    /// after the deadline has ENDED the reply — and then defiantly yields
    /// another, ignoring cancellation. The defiant token must not be heard.
    @Test("a token the source yields after the deadline is never heard")
    func aTokenAfterTheDeadlineIsNotHeard() async throws {
        let clock = ManualClock()
        let (mind, source) = mind(.gatedDefiance(before: "before", after: "AFTER-THE-DEADLINE"),
                                  clock: clock)
        let facts = Facts()
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "a question", options: GenerationOptions(deadline: .milliseconds(200))))
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 1"))
        #expect(await Wait4y.parked(clock))
        await clock.advance(by: .milliseconds(200))
        #expect(await facts.heard("ended"), "the deadline ends the stream")
        source.release()
        let updates = try await Wait4y.settled(story)
        #expect(updates == [.token("before"), .finished(.deadline)],
                "the defiant token is dropped by the retired latch")
    }

    /// The deadline is a STOP REASON on the public seam too: `reply(to:)`
    /// returns text and `.deadline`, the way it returns `.tokenBudget`.
    @Test("reply(to:) returns the partial text with stop == .deadline — a stop reason, not a failure")
    func replyReturnsTheStopReason() async throws {
        let clock = ManualClock()
        let (mind, _) = mind(.tokensThenHold(Self.twoTokens), clock: clock)
        let asked = Task {
            try await mind.reply(to: ReplyContext(
                transcript: "a long question",
                options: GenerationOptions(deadline: .milliseconds(200))))
        }
        #expect(await Wait4y.parked(clock))
        await clock.advance(by: .milliseconds(200))
        let reply = try await Wait4y.settled(asked)
        #expect(reply.text == "two tokens")
        #expect(reply.stop == .deadline)
    }
}
