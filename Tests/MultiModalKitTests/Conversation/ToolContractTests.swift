// THE TOOL CONTRACT'S TYPES (4z, SPEC §193/1–2, AC-271, AC-277; D-108 F-1 = A).
//
// The spike's tool took `[String: String]` and every tool was a parser.
// The contract's tool declares its parameters and receives
// `ToolArguments` — typed accessors that THROW a countable value — and
// the table checks the model's arguments against the declaration BEFORE
// the tool's body runs. These tests need no mind: they are the promise
// AC-271 makes, written against the types alone.

import MultiModalKit
import MultiModalKitTesting
import Testing

@Suite("4z · ToolArguments — typed accessors that throw, never guess")
struct ToolArgumentsTests {

    @Test("a number comes out of a number, an integer, or a numeric string")
    func numberCoercion() throws {
        let arguments: ToolArguments = ["a": 83.5, "b": 5, "c": "42.25"]
        #expect(try arguments.number("a") == 83.5)
        #expect(try arguments.number("b") == 5)
        #expect(try arguments.number("c") == 42.25)
    }

    @Test("an integer comes out of an integer, a whole number, or a whole string — never a fraction")
    func integerCoercion() throws {
        let arguments: ToolArguments = ["a": 5, "b": 7.0, "c": "12", "d": 7.5, "e": "7.5"]
        #expect(try arguments.integer("a") == 5)
        #expect(try arguments.integer("b") == 7)
        #expect(try arguments.integer("c") == 12)
        #expect(throws: ToolArgumentFailure(argument: "d", reason: .wrongKind(expected: .integer, got: .number(7.5)))) {
            try arguments.integer("d")
        }
        #expect(throws: ToolArgumentFailure(argument: "e", reason: .wrongKind(expected: .integer, got: .string("7.5")))) {
            try arguments.integer("e")
        }
    }

    @Test("a boolean comes out of a boolean or the words true/false, nothing else")
    func booleanCoercion() throws {
        let arguments: ToolArguments = ["a": true, "b": "false", "c": "yes", "d": 1]
        #expect(try arguments.boolean("a") == true)
        #expect(try arguments.boolean("b") == false)
        #expect(throws: ToolArgumentFailure(argument: "c", reason: .wrongKind(expected: .boolean, got: .string("yes")))) {
            try arguments.boolean("c")
        }
        #expect(throws: ToolArgumentFailure(argument: "d", reason: .wrongKind(expected: .boolean, got: .integer(1)))) {
            try arguments.boolean("d")
        }
    }

    @Test("a string is a string; a number is not quietly a string")
    func stringIsStrict() throws {
        let arguments: ToolArguments = ["food": "two eggs", "kg": 83.5]
        #expect(try arguments.string("food") == "two eggs")
        #expect(throws: ToolArgumentFailure(argument: "kg", reason: .wrongKind(expected: .string, got: .number(83.5)))) {
            try arguments.string("kg")
        }
    }

    @Test("a missing argument is .missing, and null counts as missing")
    func missing() {
        let arguments: ToolArguments = ["gone": .null]
        #expect(throws: ToolArgumentFailure(argument: "kg", reason: .missing)) { try arguments.number("kg") }
        #expect(throws: ToolArgumentFailure(argument: "gone", reason: .missing)) { try arguments.string("gone") }
        #expect(arguments.has("gone") == false, "null is absence")
        #expect(ToolArguments.none.has("anything") == false)
    }

    @Test("the failure's words name the argument, the kind wanted, and what came")
    func words() {
        #expect(ToolArgumentFailure(argument: "kg", reason: .missing).description
                == "argument 'kg' is missing")
        #expect(ToolArgumentFailure(argument: "kg", reason: .wrongKind(expected: .number, got: .string("heavy"))).description
                == "argument 'kg' should be a number, got \"heavy\"")
    }
}

@Suite("4z · the table checks the declaration before the body runs (AC-271)")
struct ToolTableValidationTests {

    /// `log_weight(kg: number, note: string?)` — Emberleaf's first verb.
    private func logWeight(_ scripted: ScriptedTool) -> ToolTable {
        ToolTable([ReplyTool(
            name: "log_weight",
            description: "Record today's body weight.",
            parameters: [
                ToolParameter(name: "kg", description: "the weight in kilograms", kind: .number),
                ToolParameter(name: "note", description: "an optional note", kind: .string, isRequired: false)
            ],
            call: scripted.tool.call)])
    }

    @Test("a required argument that is missing never reaches the body, and the model is told")
    func requiredMissing() async {
        let scripted = ScriptedTool(name: "log_weight", plan: .answers("logged"))
        let outcome = await logWeight(scripted).call("log_weight", arguments: ["note": "after run"])
        #expect(outcome == .failure(ToolCallFailure(
            tool: "log_weight",
            reason: .badArgument(ToolArgumentFailure(argument: "kg", reason: .missing)))))
        #expect(scripted.calls.isEmpty, "the body must not run on a call it cannot honour")
        #expect(outcome.failureDescription == "tool 'log_weight' cannot run: argument 'kg' is missing")
    }

    @Test("a wrong kind never reaches the body")
    func wrongKind() async {
        let scripted = ScriptedTool(name: "log_weight", plan: .answers("logged"))
        let outcome = await logWeight(scripted).call("log_weight", arguments: ["kg": "heavy"])
        #expect(outcome == .failure(ToolCallFailure(
            tool: "log_weight",
            reason: .badArgument(ToolArgumentFailure(argument: "kg", reason: .wrongKind(expected: .number, got: .string("heavy")))))))
        #expect(scripted.calls.isEmpty)
    }

    @Test("a good call runs with exactly the arguments the model gave; an optional may be absent; an extra is ignored")
    func goodCall() async {
        let scripted = ScriptedTool(name: "log_weight", plan: .answers("logged"))
        let table = logWeight(scripted)
        #expect(await table.call("log_weight", arguments: ["kg": 83.5]) == .success("logged"))
        #expect(await table.call("log_weight", arguments: ["kg": "84", "note": "morning", "mood": "fine"]) == .success("logged"))
        #expect(scripted.calls == [["kg": 83.5], ["kg": "84", "note": "morning", "mood": "fine"]])
    }

    @Test("a tool with no parameters still runs on any arguments — the spike's read is unchanged (AC-277)")
    func noParameters() async {
        let scripted = ScriptedTool(name: "session", plan: .answers("today: rest"))
        let table = ToolTable([scripted.tool])
        #expect(await table.call("session", arguments: [:]) == .success("today: rest"))
        #expect(await table.call("session", arguments: ["day": "today"]) == .success("today: rest"))
    }

    @Test("a name no tool has, and a tool that throws, keep the spike's two failures")
    func spikeFailuresKept() async {
        let broken = ScriptedTool(name: "broken", plan: .throwsError("no disk"))
        let table = ToolTable([broken.tool])
        #expect(await table.call("weather", arguments: [:])
                == .failure(ToolCallFailure(tool: "weather", reason: .unknownTool)))
        #expect(await table.call("broken", arguments: [:])
                == .failure(ToolCallFailure(tool: "broken", reason: .threw("no disk"))))
    }
}

private extension Result where Success == String, Failure == ToolCallFailure {
    var failureDescription: String? {
        if case .failure(let failure) = self { return failure.description }
        return nil
    }
}
