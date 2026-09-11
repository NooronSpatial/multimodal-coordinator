// `ToolSpikeTests`, continued: THE THREE SURVIVAL TESTS (4w, SPEC §169/3,
// AC-224..AC-226) — the turn machinery under a slow tool, a failing tool,
// and a barge while the call is in flight. The ticket doctrine (D-031)
// applied to a call nobody can cancel.

import MultiModalKit
import MultiModalKitTesting
import Testing

extension ToolSpikeTests {
    // MARK: - AC-224: a slow tool does not stall the turn machinery

    /// The tool never returns until the test says so. While the call is
    /// parked, a person barges: the coordinator must accept it — the
    /// barge event, the new listening turn, the new reply — with the old
    /// run still inside its call. Then the tool is released, and the
    /// conformant run drops the answer on its own re-check (§4.1's
    /// reentrancy law); nothing from the old turn reaches anyone.
    @Test("AC-224: a barge lands while a tool call is pending; the late answer goes nowhere")
    func aSlowToolDoesNotStallTheTurnMachinery() async throws {
        let signals = Signals()
        let tool = ScriptedTool(name: "session", plan: .waitsForRelease(then: .answers(Self.session)),
                                onEnter: { _ in signals.send("entered") })
        let script = ToolScript(name: "session", whenDone: { signals.send("reply0 done") })
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([tool.tool])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "what is today's session", at: 0)
            #expect(await signals.heard("entered"), "the run must make the call")
            #expect(await rig.bench.coordinator.currentState == .thinking)

            // THE BARGE, with the call still parked.
            await rig.bargeDuringTheCall()
            #expect(rig.reporter.cancelLatencies.map(\.1) == [0], "the cancel was measured, for the dead turn")

            // NOW the tool answers — into a run that is already dead.
            tool.release()
            #expect(await signals.heard("reply0 done"))
            #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
                ToolCallRecord(name: "session", arguments: [:],
                               outcome: .answered(Self.session), answerDropped: true)
            ], "the run saw the answer, re-checked its ticket, and dropped it")

            // The new turn runs to completion, untouched.
            await rig.completeManualTurn(1, reply: 1, utterance: 0, tokens: ("OK", "."))
            let memory = await rig.bench.coordinator.currentMemory
            #expect(memory.map(\.replied) == ["OK."], "only the new turn is remembered")
            #expect(memory.map(\.said) == ["what is today's session never mind"],
                    "a barge before the first token keeps the words (F-5 = A)")
            await rig.finish()
        }

        #expect(rig.bench.synthesizer.utterancesOpened == 1)
        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["OK", "."],
                "no token from the dead run reached the mouth")
        #expect(await rig.bench.box.events == Self.bargedSequence)
    }

    // MARK: - AC-226: a barge during a call — the ticket discards the answer

    /// **THE TEST THAT MATTERS MOST.** Same barge, same parked call — but
    /// the run is DEFIANT: when the tool answers it pushes the answer,
    /// the tail and a `.finished` into its dead stream as real ghosts.
    /// Nothing in the run protects the person now; only the coordinator's
    /// ticket does. Three proofs: the mouth never hears the answer, the
    /// memory never holds it, and the new turn's reply is exactly what
    /// its own script said.
    ///
    /// On ordering, honestly: the ghosts are yielded into the dead run's
    /// stream before the new turn is driven (`reply0 done` is that fact),
    /// and its forwarder hands them to the merge from there. The ticket
    /// check they hit — `live.turn == 0` — is false for ever after the
    /// barge, so a ghost that arrived later still could not act; the
    /// order here makes the proof direct rather than vacuous. Checked by
    /// weakening the guard on purpose: this test failed 5 of 5 runs, on
    /// every one of the three proofs.
    @Test("AC-226: a defiant run pushes the tool's late answer into a dead turn — the ticket discards it")
    func aBargeDuringACallDiscardsTheAnswerByTheTicket() async throws {
        let signals = Signals()
        let tool = ScriptedTool(name: "session", plan: .waitsForRelease(then: .answers(Self.session)),
                                onEnter: { _ in signals.send("entered") })
        let script = ToolScript(name: "session", after: [" Ready?"], ignoresCancel: true,
                                whenDone: { signals.send("reply0 done") })
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([tool.tool])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "what is today's session", at: 0)
            #expect(await signals.heard("entered"))
            await rig.bargeDuringTheCall()

            // THE GHOSTS: answer, tail, terminal — all pushed into turn 0.
            tool.release()
            #expect(await signals.heard("reply0 done"))
            #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
                ToolCallRecord(name: "session", arguments: [:],
                               outcome: .answered(Self.session), answerDropped: false)
            ], "the defiant run did NOT drop it — the ticket has to")

            await rig.completeManualTurn(1, reply: 1, utterance: 0, tokens: ("OK", "."))
            // Proof 2: never remembered.
            let memory = await rig.bench.coordinator.currentMemory
            #expect(memory.map(\.replied) == ["OK."])
            #expect(!memory.contains { $0.replied.contains("Push day") })
            await rig.finish()
        }

        // Proof 1: never spoken.
        #expect(rig.bench.synthesizer.utterancesOpened == 1)
        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["OK", "."])
        // Proof 3: the new turn's reply, and the whole stream, unaffected —
        // no ghost token, no ghost completion of turn 0.
        #expect(rig.bench.generator.record(ofReply: 1)?.history.isEmpty == true,
                "nothing of the dead turn was handed to the new mind")
        #expect(await rig.bench.box.events == Self.bargedSequence)
    }

    // MARK: - AC-225: a failing tool ends as an honest turn

    /// The tool throws and the run gives up: the terminal is `.failed`,
    /// the coordinator records a failed turn with the tool's own words,
    /// and the NEXT turn runs clean — the memory is not poisoned, the
    /// ledger still holds the unanswered words (D-040 F-2), no stale
    /// ticket blocks the new reply.
    @Test("AC-225: a throwing tool fails the turn honestly, and the next turn runs clean")
    func aFailingToolEndsAsAnHonestTurn() async throws {
        let tool = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let script = ToolScript(name: "session", onFailure: .failsReply)
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([tool.tool])),
            synthesizer: .manual(utterances: 1))
        let failure = ToolCallFailure(tool: "session", reason: .threw("the stub is offline"))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "what is today's session", at: 0)
            #expect(await rig.heard("failed:0"), "a failing tool must end the turn, not the loop")
            #expect(await rig.heard("idle:0"))
            #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
                ToolCallRecord(name: "session", arguments: [:], outcome: .failed(failure))
            ], "the failure is a typed, countable value on the side that made the call")
            #expect(await rig.bench.coordinator.currentMemory.isEmpty, "a failed turn is never remembered")

            // The next turn, clean.
            rig.bench.speak(utterance: 1, final: "asking again", at: 96_000)
            #expect(await rig.heard("thinking:1"), "no stale ticket may block the next reply")
            await rig.completeManualTurn(1, reply: 1, utterance: 0, tokens: ("Rest", " day."))
            #expect(await rig.bench.coordinator.currentMemory.map(\.replied) == ["Rest day."])
            await rig.finish()
        }

        let second = rig.bench.generator.record(ofReply: 1)
        #expect(second?.transcript == "what is today's session asking again",
                "nothing answered the first words, so the ledger keeps them (D-040 F-2)")
        #expect(second?.history.isEmpty == true, "and the memory does not also hold them")
        let expected: [TurnEvent] = [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .turnFailed(.generationFailed(failure.description), turn: 0),
            .stateChanged(.idle, turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .replyToken("Rest", turn: 1),
            .replyToken(" day.", turn: 1),
            .stateChanged(.speaking, turn: 1),
            .turnCompleted(turn: 1),
            .stateChanged(.idle, turn: 1)
        ]
        #expect(await rig.bench.box.events == expected)
    }

    /// F-4 = B, the other honest ending: the model asks for a name no
    /// tool has, the run answers it with the error, and the mind recovers
    /// IN WORDS — the person hears "I couldn't", the turn COMPLETES, and
    /// the failure is still counted on the run's record.
    @Test("AC-225 / F-4 = B: a name no tool has is answered in words, and the turn completes")
    func anUnknownToolIsRecoveredInWords() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.session))
        let script = ToolScript(name: "weather", onFailure: .speaks(["I can't ", "check that."]))
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script), .manual()],
                                              tools: ToolTable([tool.tool])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "what is the weather", at: 0)
            #expect(await rig.heard("token:check that.:0"))
            rig.bench.synthesizer.reportStarted(utterance: 0)
            #expect(await rig.heard("speaking:0"))
            rig.bench.synthesizer.reportFinished(utterance: 0)
            #expect(await rig.heard("completed:0"), "recovering in words is a COMPLETED turn")
            #expect(await rig.bench.coordinator.currentMemory.map(\.replied) == ["I can't check that."])

            // The next turn, clean: the ledger was emptied by the completion.
            rig.bench.speak(utterance: 1, final: "and the session?", at: 96_000)
            #expect(await rig.heard("thinking:1"))
            await rig.finish()
        }

        #expect(tool.calls.isEmpty, "the tool that exists was never asked")
        #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
            ToolCallRecord(name: "weather", arguments: [:],
                           outcome: .failed(ToolCallFailure(tool: "weather", reason: .unknownTool)))
        ])
        #expect(rig.bench.generator.record(ofReply: 1)?.transcript == "and the session?")
        #expect(rig.bench.generator.record(ofReply: 1)?.history.map(\.replied) == ["I can't check that."])
    }
}
