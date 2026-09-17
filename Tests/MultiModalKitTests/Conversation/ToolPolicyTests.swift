// THE WRITE AND ITS CONFIRMATION (4z, SPEC §193/8, AC-279; D-110 F-10 B,
// sub-fork B-ii).
//
// The brief's default-deny for a model-initiated write, carried as ONE
// policy bit the library enforces at the door:
//
//   the model calls a flagged tool ──► the door: is the NAME in the call's
//   confirmed set? ── no ──► the body does not run; the model is told to
//                             ask; the count says .needsConfirmation
//                    ── yes ─► the body runs, once, for that call
//
// The person's "yes" is the APP's to hear, and it marks it on the next
// call's options (`GenerationOptions.confirmedTools`) — by name. The
// model cannot say yes for the person: an argument named `confirmed`,
// even DECLARED as a boolean, is just an argument. Both callers' policies
// sit on top: Aura's spoken confirmation is a flagged tool and a spoken
// turn; the diet app's act-at-once is an unflagged tool and its own undo.
//
// The door rows have no mind; the two policy rows use the scripted mind
// through the seam, with the yes riding the call's options.

import MultiModalKit
import MultiModalKitTesting
import Testing

@Suite("4z · the write and its confirmation — one flag the door enforces, the yes on the call (AC-279)",
       .timeLimit(.minutes(1)))
struct ToolPolicyTests {
    private static let kg = ToolParameter(name: "kg", description: "kilograms", kind: .number, isRequired: true)
    /// DECLARED, so the only thing that can stop the body is the flag,
    /// not F-7 C's strip.
    private static let confirmed = ToolParameter(name: "confirmed", description: "the person said yes",
                                                 kind: .boolean, isRequired: false)
    private static let told =
        "tool 'log_weight' needs the person's confirmation: ask them, and call it again once they have said yes"

    private static func flagged() -> ScriptedTool {
        ScriptedTool(name: "log_weight", parameters: [kg, confirmed], requiresConfirmation: true,
                     plan: .answers("logged"))
    }

    private static func knock(_ tool: ScriptedTool, _ arguments: ToolArguments,
                              confirmed: Set<String>) async -> ToolCallOutcome {
        await ToolTable([tool.tool]).invoke(tool.name, arguments: arguments, confirmed: confirmed)
    }

    private static let needsConfirmation = ToolCallOutcome(
        result: .failure(ToolCallFailure(tool: "log_weight", reason: .needsConfirmation)))

    // MARK: - the door rows (AC-279 B)

    @Test("a flagged tool on the model's first call: the body does not run, the model is told to ask, counted")
    func flaggedToolIsNotRunUnconfirmed() async {
        let tool = Self.flagged()
        let outcome = await Self.knock(tool, ["kg": 83.5], confirmed: [])
        #expect(outcome == Self.needsConfirmation)
        #expect(outcome.wordsForModel == Self.told)
        #expect(tool.calls.isEmpty, "the body never ran")
    }

    @Test("`confirmed: true` in the ARGUMENTS does not run the body — the model cannot confirm itself")
    func theModelCannotConfirmItself() async {
        let tool = Self.flagged()
        let outcome = await Self.knock(tool, ["kg": 83.5, "confirmed": true], confirmed: [])
        #expect(outcome == Self.needsConfirmation)
        #expect(outcome.stripped.isEmpty, "`confirmed` is declared: it was not stripped, and it still does nothing")
        #expect(tool.calls.isEmpty)
    }

    @Test("the name in the call's confirmed set: the body runs exactly once; the yes rides THAT call only")
    func theYesOnTheCallRunsTheBodyOnce() async {
        let tool = Self.flagged()
        let yes = await Self.knock(tool, ["kg": 83.5], confirmed: ["log_weight"])
        #expect(yes.result == .success("logged"))
        #expect(tool.calls == [["kg": 83.5]], "once")

        // The set is the CALL's, not the tool's state: a later call
        // without it is refused again (B-ii — the app marks each yes).
        let again = await Self.knock(tool, ["kg": 85], confirmed: [])
        #expect(again == Self.needsConfirmation)
        #expect(tool.calls == [["kg": 83.5]], "still once")

        // Another tool's name in the set is not this tool's yes.
        let other = await Self.knock(tool, ["kg": 85], confirmed: ["add_extra"])
        #expect(other == Self.needsConfirmation)
        #expect(tool.calls.count == 1)
    }

    @Test("an unflagged tool needs no yes: the diet app's act-at-once is the flag left off")
    func unflaggedToolRunsAtOnce() async {
        let tool = ScriptedTool(name: "log_weight", parameters: [Self.kg], requiresConfirmation: false,
                                plan: .answers("logged"))
        let outcome = await Self.knock(tool, ["kg": 83.5], confirmed: [])
        #expect(outcome.result == .success("logged"))
        #expect(tool.calls == [["kg": 83.5]])
    }

    @Test("the arguments are checked BEFORE the flag is read: a bad call is refused as a bad call, not told to ask")
    func checksComeBeforeTheFlag() async {
        let tool = Self.flagged()
        let outcome = await Self.knock(tool, ["confirmed": true], confirmed: [])
        #expect(outcome == ToolCallOutcome(result: .failure(ToolCallFailure(
            tool: "log_weight",
            reason: .badArgument(ToolArgumentFailure(argument: "kg", reason: .missing))))),
                "§195's path: missing / wrong kind / extra, then the band, then the flag, then the body")
        #expect(tool.calls.isEmpty)
    }

    // MARK: - both callers' policies, on the scripted mind

    /// Aura's shape: the model calls the write; the door refuses and
    /// tells it to ask; the mind ASKS in words (a spoken turn, the app's
    /// policy); the person says yes; the app marks the name on the next
    /// call's options; that call's tool runs the body once.
    @Test("Aura's spoken confirmation: refused and asked on turn 0, run once on turn 1 with the yes on the options")
    func spokenConfirmationOnTheScriptedMind() async throws {
        let tool = ScriptedTool(name: "shorten_session", requiresConfirmation: true, plan: .answers("shortened by 10"))
        let asks = ToolScript(name: "shorten_session", onFailure: .speaks(["Shall I shorten it by ten minutes?"]))
        let runs = ToolScript(name: "shorten_session", after: [" Done."])
        let generator = ScriptedReplyGenerator(plans: [.callsTool(asks), .callsTool(runs)],
                                               tools: ToolTable([tool.tool]))

        let first = try await generator.reply(to: ReplyContext(transcript: "make it shorter"))
        #expect(first.text == "Shall I shorten it by ten minutes?")
        #expect(generator.record(ofReply: 0)?.toolCalls.map(\.outcome)
                == [.failed(ToolCallFailure(tool: "shorten_session", reason: .needsConfirmation))],
                "counted on the run's record")
        #expect(tool.calls.isEmpty, "nothing was shortened on the model's word alone")

        let second = try await generator.reply(to: ReplyContext(
            transcript: "yes", options: GenerationOptions(confirmedTools: ["shorten_session"])))
        #expect(second.text == "shortened by 10 Done.")
        #expect(tool.calls == [.empty], "the body ran exactly once, on the call that carried the yes")
    }

    /// The diet app's shape: no flag, the verb runs at once; undo is the
    /// app's own, beside its write (§194).
    @Test("the diet app's act-at-once: an unflagged write runs on the model's first call")
    func actAtOnceOnTheScriptedMind() async throws {
        let tool = ScriptedTool(name: "log_weight", parameters: [Self.kg], requiresConfirmation: false,
                                plan: .answers("logged 83.5 kg"))
        let script = ToolScript(name: "log_weight", arguments: ["kg": 83.5])
        let generator = ScriptedReplyGenerator(plans: [.callsTool(script)], tools: ToolTable([tool.tool]))
        let reply = try await generator.reply(to: ReplyContext(transcript: "log eighty-three and a half"))
        #expect(reply.text == "logged 83.5 kg")
        #expect(tool.calls == [["kg": 83.5]])
    }
}
