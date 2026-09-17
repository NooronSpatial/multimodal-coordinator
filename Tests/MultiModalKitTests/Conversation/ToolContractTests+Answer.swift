// `ToolContractTests`, continued: WHAT GOES BACK TO THE MODEL (4z, AC-276,
// AC-288, AC-290; D-110 F-13 c/e/f) — the cap on an answer, a thrown
// tool's words, the unknown-name sentence, equality by declaration, and
// the accessors a body reads with after the door.

import MultiModalKit
import MultiModalKitTesting
import Testing

extension ToolContractTests {
    // MARK: - AC-288: the answer is capped (F-13 f), the cut marked and counted

    @Test("an answer longer than the cap reaches the model cut at the cap with the marker, and the cut is counted")
    func longAnswerIsCut() async {
        let long = String(repeating: "x", count: ToolTable.answerCap + 1)
        let tool = Self.logWeight(answer: long)
        let outcome = await Self.knock(tool, ["kg": 84])
        #expect(outcome.cut == true)
        #expect(outcome.result == .success(String(repeating: "x", count: ToolTable.answerCap) + ToolTable.cutMarker))
        #expect(outcome.wordsForModel.hasSuffix(ToolTable.cutMarker))
        #expect(ToolTable.answerCap == 4_000, "sized from §69's slope: about 3 s of prefill on the 4B")
    }

    @Test("an answer of exactly the cap, and a short one, reach the model unchanged")
    func answerUnderTheCapIsUnchanged() async {
        let exact = String(repeating: "y", count: ToolTable.answerCap)
        let outcome = await Self.knock(Self.logWeight(answer: exact), ["kg": 84])
        #expect(outcome.result == .success(exact))
        #expect(outcome.cut == false)
        let short = await Self.knock(Self.logWeight(answer: "logged 84 kg"), ["kg": 84])
        #expect(short.result == .success("logged 84 kg"))
        #expect(short.cut == false)
    }

    @Test("a thrown tool's own words reach the model verbatim (F-13 e) — under the same cap")
    func thrownWordsAreVerbatimUnderTheCap() async {
        let tool = ScriptedTool(name: "log_weight", parameters: Self.declaration,
                                plan: .throwsError("the scale is offline"))
        let outcome = await Self.knock(tool, ["kg": 84])
        #expect(outcome.result == .failure(ToolCallFailure(tool: "log_weight", reason: .threw("the scale is offline"))))
        #expect(outcome.wordsForModel == "tool 'log_weight' failed: the scale is offline")
        #expect(outcome.cut == false)

        let long = String(repeating: "e", count: ToolTable.answerCap + 1)
        let loud = ScriptedTool(name: "log_weight", parameters: Self.declaration, plan: .throwsError(long))
        let cut = await Self.knock(loud, ["kg": 84])
        #expect(cut.cut == true)
        #expect(cut.result == .failure(ToolCallFailure(
            tool: "log_weight",
            reason: .threw(String(repeating: "e", count: ToolTable.answerCap) + ToolTable.cutMarker))))
    }

    // MARK: - AC-276's sentence, AC-290's equality, and the accessors

    @Test("a name no tool has: the sentence the MLX run has always fed back (AC-276)")
    func unknownToolSentence() async {
        let outcome = await ToolTable.empty.invoke("weather", arguments: .empty)
        #expect(outcome == ToolCallOutcome(result: .failure(ToolCallFailure(tool: "weather", reason: .unknownTool))))
        #expect(outcome.wordsForModel == "no tool named 'weather'")
    }

    @Test("two tables with one declaration and different bodies are equal; one parameter apart, not (F-13 c)")
    func equalityByDeclaration() {
        let one = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                            parameters: [Self.kg, Self.note], requiresConfirmation: false) { _ in "one" }
        let two = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                            parameters: [Self.kg, Self.note], requiresConfirmation: false) { _ in "two" }
        #expect(ToolTable([one]) == ToolTable([two]), "the bodies are closures: equal by declaration")

        let apart = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                              parameters: [Self.kg], requiresConfirmation: false) { _ in "one" }
        #expect(ToolTable([one]) != ToolTable([apart]), "one parameter apart")
        let flagged = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                                parameters: [Self.kg, Self.note], requiresConfirmation: true) { _ in "one" }
        #expect(ToolTable([one]) != ToolTable([flagged]), "the flag is part of the declaration (F-10 B)")
        let reworded = ReplyTool(name: "log_weight", description: "Log the weight.",
                                 parameters: [Self.kg, Self.note], requiresConfirmation: false) { _ in "one" }
        #expect(ToolTable([one]) != ToolTable([reworded]), "the words the model reads are the declaration")

        // And so GenerationOptions stays Equatable with a table on it.
        #expect(GenerationOptions(tools: ToolTable([one])) == GenerationOptions(tools: ToolTable([two])))
        #expect(GenerationOptions(tools: ToolTable([one])) != GenerationOptions(tools: ToolTable([apart])))
        #expect(GenerationOptions(tools: .empty) != GenerationOptions(), "nil is the generator's; .empty is none")
    }

    @Test("the accessors after the door: they read what the door let in, and throw a typed failure for anything else")
    func accessorsAreTypedAndStrict() throws {
        let arguments: ToolArguments = ["kg": 83.5, "count": 7, "note": "morning", "flag": true]
        #expect(try arguments.number("kg") == 83.5)
        #expect(try arguments.integer("count") == 7)
        #expect(try arguments.string("note") == "morning")
        #expect(try arguments.boolean("flag") == true)
        #expect(ToolArguments.empty.has("kg") == false)

        #expect(throws: ToolArgumentFailure(argument: "absent", reason: .missing)) {
            try arguments.number("absent")
        }
        #expect(throws: ToolArgumentFailure(argument: "kg", reason: .wrongKind(expected: .string, got: 83.5))) {
            try arguments.string("kg")
        }
        #expect(throws: ToolArgumentFailure(argument: "kg", reason: .wrongKind(expected: .integer, got: 83.5))) {
            try arguments.integer("kg")
        }
        #expect(throws: ToolArgumentFailure(argument: "note", reason: .wrongKind(expected: .boolean, got: "morning"))) {
            try arguments.boolean("note")
        }
    }
}
