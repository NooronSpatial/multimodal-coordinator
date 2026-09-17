import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// A TOOL PLUS A DEADLINE (4z, SPEC §193/7, AC-278; D-110 F-9 = A) — born
// from the merge with 4y, and the row no branch had.
//
// 4y's deadline is a race: the rounds against the clock's sleeper, and
// the terminal `.finished(.deadline)` is spoken by the rounds task ONLY,
// after its own loop has returned (`MLXReplyRun`: the flag, `report`,
// `endedByTheClock`). 4z makes the loop AWAIT a tool's body through the
// door, and the door shields the body from the reply's cancellation
// (F-5 = A). So what does the clock do while a body runs? F-9 = A: the
// deadline WAITS for the body. Read off the code, that is what the
// rounds task must do once it awaits the door; this row is where the
// reading becomes a fact — and the row that keeps it one.
//
// What a test SEES, per AC-278 under A: the write happens exactly once;
// `.finished(.deadline)` is spoken AFTER the body has ended; the terminal
// is spoken exactly once, and last. Under `ManualClock`, waiting on
// EVENTS — "entered", "written", "ended" — never on time.

@Suite("AC-278 · the deadline waits for a running tool body: one write, then .finished(.deadline), once and last",
       .timeLimit(.minutes(1)))
struct MLXToolDeadlineTests {
    private static let kg = ToolParameter(name: "kg", description: "kilograms", kind: .number, isRequired: true)
    private static let call = ToolCallRequest(name: "log_reading", arguments: ["kg": 83.5])

    /// The app's record: how many times the write COMMITTED.
    private final class Writes: Sendable {
        private let count = Mutex(0)
        func commit() { count.withLock { $0 += 1 } }
        var total: Int { count.withLock { $0 } }
    }

    /// A COOPERATIVE writing tool — the kind an app writes, AC-277's:
    /// it parks at a gate the test opens, looks at the cancellation flag
    /// before it commits, and writes. If the deadline's cancellation
    /// reached the body, the write would be skipped here.
    private static func writer(facts: Facts, gate: ToolSpikeTests.Gate, writes: Writes) -> ReplyTool {
        ReplyTool(name: "log_reading", description: "Record today's body weight.",
                  parameters: [kg], requiresConfirmation: false) { _ in
            facts.send("entered")
            await gate.wait()
            guard !Task.isCancelled else {
                facts.send("aborted")
                return "aborted"
            }
            writes.commit()
            facts.send("written")
            return "logged 83.5 kg"
        }
    }

    @Test("the deadline fires while the body is parked: the write lands once, then ONE terminal, the clock's, last")
    func theDeadlineWaitsForTheBody() async throws {
        let clock = ManualClock()
        let facts = Facts()
        let gate = ToolSpikeTests.Gate()
        let writes = Writes()
        let source = ScriptedTokenSource(.rounds([
            [.token("Let me log that. "), .toolCall(Self.call), .stopped(.complete)],
            [.token("Logged."), .stopped(.complete)]
        ]), tools: ToolTable([Self.writer(facts: facts, gate: gate, writes: writes)]))
        let mind = MLXReplyGenerator(source: source, clock: clock)
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "log eighty-three and a half",
            options: GenerationOptions(deadline: .milliseconds(200))))
        let story = ReplyStory.collect(run, facts: facts)

        // The FACTS the test waits on: the body is parked in the gate, and
        // the deadline is asleep on THIS clock.
        #expect(await facts.heard("entered"), "the run knocked the door and the body began")
        #expect(await Wait4y.parked(clock), "the deadline is asleep on this clock, not on wall time")
        #expect(writes.total == 0, "nothing is written while the tool is parked")

        // THE DEADLINE, with the body still parked. The sleeper wakes, the
        // flag goes up, the rounds task is cancelled — and it is awaiting
        // the door. Read after `advance` has settled, not waited for: the
        // sleeper is gone (removed under the clock's lock before it was
        // woken — a fact, not a race), and the reply has NOT ended. That
        // negative is a fact under F-9 A — nothing can speak the terminal
        // before the gate opens, because the only speaker is awaiting the
        // door — so this row cannot flake; the ORDER pin below is what
        // convicts a design that speaks at the deadline.
        await clock.advance(by: .milliseconds(200))
        #expect(clock.sleeperCount == 0, "the sleeper woke")
        #expect(!facts.log.contains("ended"), "the terminal is not spoken while the body runs: \(facts.log)")
        #expect(writes.total == 0, "the deadline itself writes nothing")

        // The body is let out into a reply the clock has ended: it writes,
        // once, and only THEN does the run speak the clock's word.
        gate.open()
        let updates = try await Wait4y.settled(story)
        #expect(writes.total == 1, "exactly one write — the deadline is not a cancel of the body (F-5 = A)")
        #expect(await facts.heard("written"), "the tool ran to its end")
        let log = facts.log
        let written = try #require(log.firstIndex(of: "written"))
        let ended = try #require(log.firstIndex(of: "ended"))
        #expect(written < ended, ".finished(.deadline) is spoken AFTER the body ends: \(log)")
        #expect(!log.contains("aborted"), "the body never saw the cancellation")

        #expect(updates == [.token("Let me log that. "), .finished(.deadline)],
                "the words before the call, then ONE terminal — the clock's — and nothing after it")
        #expect(ReplyConformanceKit.terminals(in: updates) == [.finished(.deadline)])
        #expect(source.askedAfter.count == 1, "no round 1: the answer died with the deadline")
        #expect(await Wait4y.fact { await (run as? MLXReplyRun)?.awaitWorkerEnd() })
        #expect(clock.sleeperCount == 0, "no sleeper survives the run")
    }

    /// The other order, for contrast: a body that ENDS before the clock
    /// does — the round continues, the answer goes back, and the deadline
    /// cuts the NEXT round instead. One terminal either way.
    @Test("a body that ends before the deadline feeds its answer back; the deadline then ends the next round")
    func aBodyThatEndsFirstIsFedBack() async throws {
        let clock = ManualClock()
        let facts = Facts()
        let gate = ToolSpikeTests.Gate()
        let writes = Writes()
        gate.open()
        let source = ScriptedTokenSource(.rounds([
            [.toolCall(Self.call), .stopped(.complete)],
            [.token("Logged"), .stopped(.complete)]
        ]), tools: ToolTable([Self.writer(facts: facts, gate: gate, writes: writes)]))
        let mind = MLXReplyGenerator(source: source, clock: clock)
        let run = try await mind.openReply(to: ReplyContext(
            transcript: "log eighty-three and a half",
            options: GenerationOptions(deadline: .seconds(30))))
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("Logged"), .finished(.complete)])
        #expect(writes.total == 1)
        #expect(source.askedAfter.last?.first?.answer == "logged 83.5 kg", "the answer went back to the model")
        #expect(await Wait4y.fact { await (run as? MLXReplyRun)?.awaitWorkerEnd() })
        #expect(clock.sleeperCount == 0, "the sleeper was cancelled with the race")
    }
}
