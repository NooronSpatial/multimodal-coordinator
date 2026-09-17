// A BARGE DURING A TOOL THAT WRITES (4z, SPEC §193/7, AC-277; D-110 F-5 = A).
//
// AC-224 proved the turn machinery survives a barge while a call is
// parked, and that the late ANSWER goes nowhere. This row is about the
// tool's EFFECT. The diet app's `log_weight` writes a record; Aura's
// `shorten_session` changes a plan. F-5 = A says: the tool's body runs
// to its end, its result dies with the ticket, and the app's state
// stands — a write is never half-done by a cancellation, and the app
// that wants "nothing happened" has undo or a spoken confirmation, not
// a cancelled task. The proof: the write happens EXACTLY once, after
// the barge, and the next turn neither hears the answer nor writes again.
//
// WHY THE TOOL LOOKS AT THE FLAG. A cooperative tool — one that reads
// `Task.isCancelled` before it commits — is the kind an app writes, and
// it is the one that bit on the reference branch: the run's cancellation
// reached into the body and the write was skipped. Written first, on
// Ryad's order ("AC-6's test first — it bit before"), against the spike's
// code as it stands: the scripted run awaits the body in its own task
// and cancels that task on a barge, so this test is RED until the door
// shields the body (F-5 = A).
//
// EVENTS ONLY (§3.3): "entered", "written", "reply0 done" and the
// coordinator's own events are the facts waited on; the slow part of the
// tool is a gate the TEST opens, never a sleep.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

extension ToolSpikeTests {
    /// The slow part of a writing tool, under the test's hand: the body
    /// waits here until the test says `open()`. Opening before anyone
    /// waits is remembered (the same rule as `ScriptedTool.release`), and
    /// the wait is a plain continuation, so a cancelled task stays parked
    /// too — that is the point: the tool must be let out INTO a barged
    /// reply, and then decide for itself.
    final class Gate: Sendable {
        private let state = Mutex<(waiting: CheckedContinuation<Void, Never>?, opened: Bool)>((nil, false))

        func open() {
            // Snapshot under the lock, resume OUTSIDE it (§4.1's second rule).
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.opened = true
                return state.waiting.take()
            }
            waiting?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let openNow = state.withLock { state -> Bool in
                    if state.opened { return true }
                    state.waiting = continuation
                    return false
                }
                if openNow { continuation.resume() }
            }
        }
    }

    // MARK: - AC-277 under F-5 = A

    /// The write is the thing: the tool parks, a person barges, the tool
    /// is let out into a dead reply — and it still writes, once. The
    /// answer is dropped by the run's own re-check of its ticket
    /// (`answerDropped`), the mouth never hears it, the memory never
    /// holds it, and the next turn runs clean without a second write.
    @Test("AC-277: a barge during a writing tool — one write, the answer dies, the next turn is clean (F-5 = A)")
    func aBargeDoesNotUnwrite() async throws {
        let signals = Signals()
        let gate = Gate()
        let writes = Mutex(0)
        let logWeight = ReplyTool(name: "log_weight",
                                  description: "Record today's body weight.") { _ in
            signals.send("entered")
            await gate.wait()
            // A COOPERATIVE tool — the kind an app writes: it looks at the
            // cancellation flag before it commits. If the barge reached
            // this body as a cancellation, the write is skipped here, and
            // F-5 = A is a sentence, not a fact.
            guard !Task.isCancelled else {
                signals.send("aborted")
                return "aborted"
            }
            writes.withLock { $0 += 1 }
            signals.send("written")
            return "logged 83.5 kg"
        }
        let script = ToolScript(name: "log_weight", arguments: ["kg": "83.5"],
                                whenDone: { signals.send("reply0 done") })
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([logWeight])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "log eighty-three and a half", at: 0)
            #expect(await signals.heard("entered"), "the run must make the call")
            #expect(writes.withLock { $0 } == 0, "nothing is written while the tool is parked")

            // THE BARGE, with the call still parked inside the gate.
            await rig.bargeDuringTheCall()
            #expect(writes.withLock { $0 } == 0, "the barge itself writes nothing")

            // The tool is let out into a dead reply: it finishes its work.
            // "reply0 done" is sent after the body has RETURNED, so once
            // it is heard the write has happened or never will — the
            // "written" check after it is a fact, not a wait.
            gate.open()
            #expect(await signals.heard("reply0 done"))
            #expect(writes.withLock { $0 } == 1, "exactly one write — a barge is not a cancel (F-5 = A)")
            #expect(await signals.heard("written", within: .seconds(1)), "the tool ran to its end")
            #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
                ToolCallRecord(name: "log_weight", arguments: ["kg": "83.5"],
                               outcome: .answered("logged 83.5 kg"), answerDropped: true)
            ], "the answer was dropped by the run's own re-check of its ticket; the write was not")

            // The next turn runs clean: no second write, no ghost of the answer.
            await rig.completeManualTurn(1, reply: 1, utterance: 0, tokens: ("OK", "."))
            #expect(writes.withLock { $0 } == 1, "the next turn did not write again")
            let memory = await rig.bench.coordinator.currentMemory
            #expect(memory.map(\.replied) == ["OK."], "the dead turn's answer is nowhere in memory")
            await rig.finish()
        }

        #expect(rig.bench.synthesizer.utterancesOpened == 1)
        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["OK", "."],
                "the mouth never heard 'logged'")
        #expect(await rig.bench.box.events == Self.bargedSequence)
    }
}
