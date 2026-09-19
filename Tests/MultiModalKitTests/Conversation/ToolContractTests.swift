// THE DOOR, WITH NO MIND (4z, SPEC §195 AC-273, AC-274, AC-276, AC-280,
// AC-288, AC-290; D-110 F-7 C, F-8 C, F-11 B, F-13 b/c/e/f/i/j).
//
// One path, and a row that watches each stop on it:
//
//   model's call ──► unknown name? ──► extra stripped (F-7 C, counted)
//     ──► missing / null / wrong kind / coerced (F-8 C, counted)
//     ──► out of the band (F-11 B) ──► needs the person's yes (F-10 B)
//     ──► BODY ──► the answer, cut at the cap (F-13 f, counted) ──► words
//
// Every row is pure: a table is built, the door is knocked, the outcome
// is read. No mind, no clock, no task. The scripted tool records what
// its BODY received, and the outcome says what the door decided — so a
// row can prove both "the body never saw it" and "the count says so".

import MultiModalKit
import MultiModalKitTesting
import Testing

@Suite("4z · the door: what reaches a tool's body, and what the model is told", .timeLimit(.minutes(1)))
struct ToolContractTests {
    // MARK: - the declaration under test

    /// The diet app's verb, declared the way the contract asks: a
    /// required number, an optional note, an optional whole number, an
    /// optional flag. `isRequired` is written on every one (F-13 k).
    static let kg = ToolParameter(name: "kg", description: "kilograms", kind: .number, isRequired: true)
    static let note = ToolParameter(name: "note", description: "a remark", kind: .string, isRequired: false)
    static let count = ToolParameter(name: "count", description: "how many", kind: .integer, isRequired: false)
    static let flag = ToolParameter(name: "flag", description: "yes or no", kind: .boolean, isRequired: false)
    static let declaration = [kg, note, count, flag]

    /// A fresh tool per row, so `calls` is that row's alone.
    static func logWeight(answer: String = "logged") -> ScriptedTool {
        ScriptedTool(name: "log_weight", parameters: declaration, plan: .answers(answer))
    }

    /// One knock at the door.
    static func knock(_ tool: ScriptedTool, _ arguments: ToolArguments,
                      confirmed: Set<String> = []) async -> ToolCallOutcome {
        await ToolTable([tool.tool]).invoke(tool.name, arguments: arguments, confirmed: confirmed)
    }

    static func refused(_ argument: String, _ reason: ToolArgumentFailure.Reason) -> ToolCallOutcome {
        ToolCallOutcome(result: .failure(ToolCallFailure(
            tool: "log_weight",
            reason: .badArgument(ToolArgumentFailure(argument: argument, reason: reason)))))
    }

    // MARK: - AC-273: missing, null, wrong kind — the body never runs

    @Test("a required parameter absent: the body does not run, the model is told, the count says .missing")
    func missingRequired() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["note": "morning"])
        #expect(outcome == Self.refused("kg", .missing))
        #expect(outcome.wordsForModel == "tool 'log_weight' cannot run: argument 'kg' is missing")
        #expect(tool.calls.isEmpty, "the body never saw the call")
    }

    @Test("null for a required parameter is absence, counted .missing (F-13 j)")
    func nullIsAbsent() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": .null])
        #expect(outcome == Self.refused("kg", .missing))
        #expect(tool.calls.isEmpty)
    }

    @Test("a value of a kind the parameter cannot read: refused as wrong kind, the body does not run")
    func wrongKind() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": true])
        #expect(outcome == Self.refused("kg", .wrongKind(expected: .number, got: true)))
        #expect(outcome.wordsForModel == "tool 'log_weight' cannot run: argument 'kg' should be a number, got true")
        #expect(tool.calls.isEmpty)
    }

    @Test("a nested value for a .string parameter is wrong kind, counted (F-13 i) — a list and an object")
    func nestedIsWrongKind() async {
        let list = Self.logWeight()
        let listed = await Self.knock(list, ["kg": 84, "note": .array([1, 2])])
        #expect(listed == Self.refused("note", .wrongKind(expected: .string, got: .array([1, 2]))))
        #expect(listed.wordsForModel == "tool 'log_weight' cannot run: argument 'note' should be a string, got a list")
        #expect(list.calls.isEmpty)

        let object = Self.logWeight()
        let objected = await Self.knock(object, ["kg": 84, "note": .object(["a": 1])])
        #expect(objected == Self.refused("note", .wrongKind(expected: .string, got: .object(["a": 1]))))
        #expect(object.calls.isEmpty)
    }

    @Test("84.5 for an integer parameter is refused as wrong kind (F-13 b)")
    func nonWholeForInteger() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 84, "count": 84.5])
        #expect(outcome == Self.refused("count", .wrongKind(expected: .integer, got: 84.5)))
        #expect(outcome.wordsForModel
                == "tool 'log_weight' cannot run: argument 'count' should be a whole number, got 84.5")
        #expect(tool.calls.isEmpty)
    }

    @Test("a number for a string parameter is refused: the leniency is one way (F-8 C keeps the branch's asymmetry)")
    func numberForString() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 84, "note": 7])
        #expect(outcome == Self.refused("note", .wrongKind(expected: .string, got: 7)))
        #expect(tool.calls.isEmpty)
    }

    // MARK: - F-13 (b): ONE number case — 84 on both minds is one value

    @Test("84 parsed on the MLX side and 84.0 read on the Apple side are ONE ToolValue, and the door reads both alike")
    func oneNumberCase() async throws {
        #expect((84 as ToolValue) == (84.0 as ToolValue), "one case: the literal matches both minds")
        #expect(ToolValue.number(84) == 84)
        // The same whole value satisfies a .number AND an .integer parameter.
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 84, "count": 84.0])
        #expect(outcome.result == .success("logged"))
        #expect(outcome.coerced.isEmpty, "an exact kind is not a coercion")
        #expect(tool.calls == [["kg": 84, "count": 84]])
        #expect(try tool.calls.first?.integer("count") == 84, "the accessor reads the exact whole the door let in")
        #expect(try tool.calls.first?.number("kg") == 84)
    }

    // MARK: - F-8 C: lenient kinds, finite only, COUNTED at the door

    @Test("\"84\" for a number parameter reads 84, the body runs, and the coercion is counted (F-8 C)")
    func textNumberIsCoercedAndCounted() async throws {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": "84"])
        #expect(outcome.result == .success("logged"))
        #expect(outcome.coerced == ["kg"], "the door counted the coercion")
        #expect(tool.calls == [["kg": 84]], "the body received the NUMBER, not the text")
        #expect(try tool.calls.first?.number("kg") == 84)
    }

    @Test("\"7\" for an integer and \"true\" for a boolean are coerced and counted; \"7.5\" for an integer is not")
    func textIntegerAndBooleanAreCoerced() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 83.5, "count": "7", "flag": "true"])
        #expect(outcome.result == .success("logged"))
        #expect(outcome.coerced == ["count", "flag"], "in declaration order")
        #expect(tool.calls == [["kg": 83.5, "count": 7, "flag": true]])

        let strict = Self.logWeight()
        let refused = await Self.knock(strict, ["kg": 83.5, "count": "7.5"])
        #expect(refused == Self.refused("count", .wrongKind(expected: .integer, got: "7.5")))
        #expect(strict.calls.isEmpty)
    }

    @Test("\"nan\" and \"inf\" for a number parameter are refused (F-8 C closes the hole)")
    func nanAndInfAreRefused() async {
        for text in ["nan", "inf", "-inf", "infinity"] {
            let tool = Self.logWeight()
            let outcome = await Self.knock(tool, ["kg": .string(text)])
            #expect(outcome == Self.refused("kg", .wrongKind(expected: .number, got: .string(text))), "\(text)")
            #expect(tool.calls.isEmpty, "\(text) never reached the body")
        }
    }

    @Test("an optional parameter not given, or given as null, is simply not there for the body")
    func optionalAbsent() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 84, "note": .null])
        #expect(outcome.result == .success("logged"))
        #expect(tool.calls == [["kg": 84]], "null is not handed on; the body's `has` says no")
        #expect(tool.calls.first?.has("note") == false)
        #expect(tool.calls.first?.has("kg") == true)
    }

    // MARK: - AC-274: an unknown extra is stripped and counted (F-7 C)

    @Test("an argument the tool never declared is stripped before the body and counted (F-7 C)")
    func unknownExtraIsStrippedAndCounted() async {
        let tool = Self.logWeight()
        let outcome = await Self.knock(tool, ["kg": 84, "mood": "fine", "kilos": 84])
        #expect(outcome.result == .success("logged"), "the call is not refused")
        #expect(outcome.stripped == ["kilos", "mood"], "counted, sorted")
        #expect(tool.calls == [["kg": 84]], "the body sees only declared names")
        #expect(tool.calls.first?.has("mood") == false)
    }

    @Test("the spike's no-argument tool: an extra is stripped, the body runs with nothing (AC-283)")
    func noArgumentToolStripsEverything() async {
        let tool = ScriptedTool(name: "session", plan: .answers("green"))
        let outcome = await Self.knock(tool, ["day": "today"])
        #expect(outcome.result == .success("green"))
        #expect(outcome.stripped == ["day"])
        #expect(tool.calls == [.empty])
    }

    // MARK: - AC-280 (the checked half): out of the band never reaches the body (F-11 B)

    static let banded = ToolParameter(name: "kg", description: "kilograms", kind: .number, isRequired: true,
                                      range: 20...300, showsRange: false)

    @Test("a value outside the declared band is refused before the body, told in words, and counted under its own name")
    func outOfRangeIsRefused() async {
        let tool = ScriptedTool(name: "log_weight", parameters: [Self.banded], plan: .answers("logged"))
        let zero = await Self.knock(tool, ["kg": 0])
        #expect(zero == Self.refused("kg", .outOfRange(allowed: 20...300, got: 0)))
        #expect(zero.wordsForModel == "tool 'log_weight' cannot run: argument 'kg' should be between 20 and 300, got 0")
        let high = await Self.knock(tool, ["kg": 300.5])
        #expect(high == Self.refused("kg", .outOfRange(allowed: 20...300, got: 300.5)))
        #expect(tool.calls.isEmpty, "neither reached the body")
    }

    @Test("inside the band — the edges included — the body runs; a coerced text is checked against the band too")
    func insideTheBandRuns() async {
        let tool = ScriptedTool(name: "log_weight", parameters: [Self.banded], plan: .answers("logged"))
        #expect(await Self.knock(tool, ["kg": 83.5]).result == .success("logged"))
        #expect(await Self.knock(tool, ["kg": 20]).result == .success("logged"), "a closed band: 20 is in")
        #expect(await Self.knock(tool, ["kg": 300]).result == .success("logged"), "and 300 is in")
        #expect(tool.calls == [["kg": 83.5], ["kg": 20], ["kg": 300]])
        let coerced = await Self.knock(tool, ["kg": "0"])
        #expect(coerced == Self.refused("kg", .outOfRange(allowed: 20...300, got: 0)),
                "\"0\" reads as 0 (F-8 C), then the band refuses it")
    }

    @Test("a band on an integer parameter is checked the same way")
    func bandOnAnInteger() async {
        let minutes = ToolParameter(name: "minutes", description: "how long", kind: .integer, isRequired: true,
                                    range: 1...120, showsRange: true)
        let tool = ScriptedTool(name: "set_timer", parameters: [minutes], plan: .answers("set"))
        let outcome = await Self.knock(tool, ["minutes": 0])
        #expect(outcome == ToolCallOutcome(result: .failure(ToolCallFailure(
            tool: "set_timer",
            reason: .badArgument(ToolArgumentFailure(argument: "minutes",
                                                     reason: .outOfRange(allowed: 1...120, got: 0)))))))
        #expect(await Self.knock(tool, ["minutes": 10]).result == .success("set"))
    }

    @Test("\"shown to the model\" and \"checked by the table\" are two switches: the parameter carries both")
    func twoSwitches() {
        #expect(Self.banded.range == 20...300)
        #expect(Self.banded.showsRange == false, "checked, not shown")
        let shown = ToolParameter(name: "kg", description: "kilograms", kind: .number, isRequired: true,
                                  range: 20...300, showsRange: true)
        #expect(shown.showsRange == true)
        #expect(Self.kg.range == nil, "no band declared")
        #expect(Self.kg.showsRange == false, "nothing to show")
    }
}
