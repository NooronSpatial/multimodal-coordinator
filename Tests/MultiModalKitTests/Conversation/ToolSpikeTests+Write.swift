// A BARGE DURING A TOOL THAT WRITES (4z, SPEC §193/7, AC-274; D-108 F-5 = A).
//
// AC-224 proved the turn machinery survives a barge while a call is
// parked, and that the late ANSWER goes nowhere. This row is about the
// tool's EFFECT. Emberleaf's `log_weight` writes a record; Aura's
// `shorten_session` changes a plan. F-5 ruled A: the tool runs to its
// end, its result dies with the ticket, and the app's state stands — a
// write cannot be half-done by cancellation, and the app that wants
// "nothing happened" has undo or a spoken confirmation, not a cancelled
// task. The proof: the write happens exactly once, after the barge,
// and the next turn neither sees the answer nor writes again.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

extension ToolSpikeTests {
    @Test("AC-274: a barge during a writing tool — the write happens once, the answer dies, the next turn is clean (F-5 = A)")
    func aBargeDoesNotUnwrite() async throws {
        let signals = Signals()
        let writes = Mutex(0)
        // The scripted tool parks until released; the WRITE is what the
        // real tool does after the slow part — here, after the park.
        let parked = ScriptedTool(name: "log_weight", plan: .waitsForRelease(then: .answers("logged 83.5 kg")),
                                  onEnter: { _ in signals.send("entered") })
        let logWeight = ReplyTool(
            name: "log_weight",
            description: "Record today's body weight.",
            parameters: [ToolParameter(name: "kg", description: "kilograms", kind: .number)]) { arguments in
                let answer = try await parked.tool.call(arguments)
                // A COOPERATIVE tool — the kind an app writes: it looks at
                // the cancellation flag before it commits. If the barge had
                // reached this task as a cancellation, the write would be
                // skipped here, and F-5 = A would be a sentence, not a fact.
                guard !Task.isCancelled else {
                    signals.send("aborted")
                    return "aborted"
                }
                writes.withLock { $0 += 1 }
                signals.send("written")
                return answer
            }
        let script = ToolScript(name: "log_weight", arguments: ["kg": 83.5],
                                whenDone: { signals.send("reply0 done") })
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([logWeight])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "log eighty three and a half", at: 0)
            #expect(await signals.heard("entered"), "the run must make the call")
            #expect(writes.withLock { $0 } == 0, "nothing is written while the tool is parked")

            // THE BARGE, with the call still parked.
            await rig.bargeDuringTheCall()

            // The tool is let out into a dead run: it finishes its work.
            parked.release()
            #expect(await signals.heard("written"), "the tool ran to its end — a barge is not a cancel (F-5 = A)")
            #expect(await signals.heard("reply0 done"))
            #expect(writes.withLock { $0 } == 1, "exactly one write")
            #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
                ToolCallRecord(name: "log_weight", arguments: ["kg": 83.5],
                               outcome: .answered("logged 83.5 kg"), answerDropped: true)
            ], "the answer was dropped by the run's own re-check; the write was not")

            // The next turn runs clean: no second write, no ghost of the answer.
            await rig.completeManualTurn(1, reply: 1, utterance: 0, tokens: ("OK", "."))
            #expect(writes.withLock { $0 } == 1, "the next turn did not write again")
            let memory = await rig.bench.coordinator.currentMemory
            #expect(memory.map(\.replied) == ["OK."], "the dead turn's answer is nowhere in memory")
            await rig.finish()
        }

        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["OK", "."],
                "the mouth never heard 'logged'")
        #expect(await rig.bench.box.events == Self.bargedSequence)
    }
}
