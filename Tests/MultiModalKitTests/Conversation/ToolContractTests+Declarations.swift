// `ToolContractTests`, continued: THE CHECK ON THE DECLARATIONS (4z piece
// 2b, AC-289; D-110 F-13 d) — what no mind can show the model, refused
// where the table is handed over, never inside a reply.
//
// Mind-agnostic, so it is proved here with no mind at all: a table is
// built, the check is asked, the typed error is read. The two minds'
// doors (`MLXReplyGenerator.init`, `openReply`; the Apple mind's with
// its own piece) call this one check, and their rows prove only that
// they do — the rule itself lives here.

import MultiModalKit
import MultiModalKitTesting
import Testing

extension ToolContractTests {
    /// The one thing the rule refuses: two parameters of ONE tool, one
    /// name — the kilogram declared twice.
    static let twiceKg = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                                   parameters: [kg, kg], requiresConfirmation: false) { _ in "logged" }

    // MARK: - AC-289: the typed refusal, and its words

    @Test("two parameters of one tool with one name: the check throws the typed error naming tool and parameter")
    func duplicateParameterIsRefused() {
        let refusal = ToolDeclarationError.duplicateParameter(tool: "log_weight", parameter: "kg")
        #expect(throws: refusal) { try ToolTable([Self.twiceKg]).checkDeclarations() }
        #expect(refusal.description == "tool 'log_weight' declares the parameter 'kg' more than once",
                "the words an app reads: WHICH tool, WHICH parameter")
    }

    /// Two different names with the same spelling but a different case
    /// are two names (the lookup rule is case-sensitive; so is this).
    @Test("a clean table passes: four distinct parameters, a tool with none, the empty table, names apart by case")
    func cleanTablesPass() throws {
        try ToolTable([Self.logWeight().tool]).checkDeclarations()
        let read = ReplyTool(name: "session", description: "Read today's session.",
                             parameters: [], requiresConfirmation: false) { _ in "" }
        try ToolTable([read, Self.logWeight().tool]).checkDeclarations()
        try ToolTable.empty.checkDeclarations()
        let apartByCase = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                                    parameters: [
                                        Self.kg,
                                        ToolParameter(name: "KG", description: "shouted",
                                                      kind: .number, isRequired: false)
                                    ], requiresConfirmation: false) { _ in "" }
        try ToolTable([apartByCase]).checkDeclarations()
    }

    /// The FIRST offence is the one named — in table order, then in
    /// declaration order — so an app with two mistakes reads them one at
    /// a time and the sentence is deterministic.
    @Test("the first offence in table order, then declaration order, is the one named")
    func theFirstOffenceIsNamed() {
        let laterTool = ToolTable([Self.logWeight().tool, Self.twiceKg])
        #expect(throws: ToolDeclarationError.duplicateParameter(tool: "log_weight", parameter: "kg")) {
            try laterTool.checkDeclarations()
        }
        let twoOffences = ReplyTool(name: "log_reading", description: "Record one reading.",
                                    parameters: [Self.kg, Self.note, Self.note, Self.kg],
                                    requiresConfirmation: false) { _ in "" }
        #expect(throws: ToolDeclarationError.duplicateParameter(tool: "log_reading", parameter: "note")) {
            try ToolTable([twoOffences]).checkDeclarations()
        }
    }

    /// The boundary of the rule, pinned: two TOOLS with one name are not
    /// refused — the table's lookup ("exact name, first match") already
    /// says what that means, and the 4w fixture row renders such a table.
    @Test("two tools with one name are not the check's business: the lookup rule already defines them")
    func twoToolsOneNameIsNotRefused() throws {
        let first = Self.logWeight(answer: "first").tool
        let second = Self.logWeight(answer: "second").tool
        try ToolTable([first, second]).checkDeclarations()
    }

    /// The door is untouched by the check — F-13 (d) is a rule on the
    /// declaration, not on `invoke`: a table the check passes is knocked
    /// exactly as before. Pinned beside the rule so the two cannot drift.
    @Test("the door reads a checked table exactly as before: the same knock, the same answer")
    func theDoorIsUnchanged() async throws {
        let tool = Self.logWeight()
        try ToolTable([tool.tool]).checkDeclarations()
        let outcome = await Self.knock(tool, ["kg": 84, "note": "morning"])
        #expect(outcome == ToolCallOutcome(result: .success("logged")))
        #expect(tool.calls == [["kg": 84, "note": "morning"]])
    }
}
