import Foundation
import MLXLMCommon
import MultiModalKit

// THE LOCAL MIND'S SIDE OF A TOOL CALL (4w, SPEC §169/1–2, AC-222; D-101;
// the contract's parameters and typed arguments since 4z, §193/4, D-110).
//
// Everything here is a pure function or a plain value — a `ReplyTool`
// in, the vendor's spec out (its parameters as the template's schema);
// the vendor's parsed call in, the seam's TYPED request out; a tool's
// answer in, the template-safe text out; a count in, a refusal out.
// None of it needs weights, a GPU or a metallib, which is why it lives
// apart from `LocalMind.swift`, the same split `MLXGeneration.swift`
// made for 4v: the live path is proven by gated tests that need all
// three, and the RULES it applies are proven here on every machine.
//
// A VENDOR FACT, CORRECTED HERE BECAUSE THE SPEC RECORDS THE OLD ONE.
// §168 says `generateTokens` "emits a `.toolCall(ToolCall)` event
// beside `.token`". Read in the build, it does not: `generateTokens`
// yields `TokenGeneration`, which is `.token(Int)` and `.info` and
// nothing else — the switch in `LocalMind.swift` was already exhaustive
// with no default arm. `.toolCall` is a case of `Generation`, the TEXT
// stream from the vendor's `generate(...)`, and it is produced there by
// a `ToolCallProcessor` run over the decoded chunks. This mind cannot
// take that path: the think gate must run on the token ID (§86 layer
// 2) — so the same public processor is fed OUR gated, detokenised
// pieces instead (`ToolCallSieve`, `LocalMind+Tools.swift`). Same
// parser, same format table, same `.toolCall`; only the loop that owns
// it is ours.

// MARK: - the call, as the token seam carries it

/// One call the model asked for, in the contract's shape (4z, F-1 = A:
/// `ToolArguments`, the value the door checks and the body receives).
/// Built from the vendor's `ToolCall` by `init(vendor:)`; built by hand
/// by a scripted source, so the run's arm is proven without a model.
struct ToolCallRequest: Sendable, Equatable {
    let name: String
    let arguments: ToolArguments

    init(name: String, arguments: ToolArguments = .empty) {
        self.name = name
        self.arguments = arguments
    }
}

/// One call and what went back to the model — the pair the NEXT round's
/// prompt is built from: an assistant turn carrying the call, then a
/// `.tool` message carrying the answer, in the template's own roles.
///
/// The answer is a `String` either way (F-4 = B): a tool that answered
/// hands its words; a name no tool has, or a tool that threw, hands
/// `ToolCallFailure.description` — and the model recovers in words.
struct ToolExchange: Sendable, Equatable {
    let request: ToolCallRequest
    let answer: String
}

// MARK: - the spec the model is shown (AC-222; the parameters since 4z, AC-271)

extension ReplyTool {
    /// The `ToolSpec` the vendor renders into the chat template — the
    /// `<tools>` block the model reads before the question.
    ///
    /// THE PARAMETERS (4z, AC-271, F-1 = A) render as the JSON-schema
    /// object every chat template of this family reads: one property per
    /// `ToolParameter` — its kind's JSON type and the app's sentence
    /// (D-027), and, for a band the app chose to SHOW (F-11 B's first
    /// switch, `showsRange`), `minimum` and `maximum`; then `required`
    /// naming the ones the model may not leave out, in declaration
    /// order. A hidden band renders nothing: the door still checks it
    /// (the second switch), and the model is shown the same bytes as
    /// for a parameter with no band.
    ///
    /// A tool with NO parameters renders the spike's bytes EXACTLY — an
    /// empty `properties` and NO `required` key (an empty list would be
    /// one more token for nothing, and a moved byte is a moved prompt,
    /// AC-227's measurement with it). The 4w fixture row pins this.
    var toolSpec: ToolSpec {
        var schema: [String: any Sendable] = [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: parameters.map { parameter in
                (parameter.name, parameter.property)
            }) as [String: any Sendable]
        ]
        let required = parameters.filter(\.isRequired).map(\.name)
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": schema
            ] as [String: any Sendable]
        ]
    }
}

// Qualified: the vendor (MLXLMCommon) has a `ToolParameter` of its own.
extension MultiModalKit.ToolParameter {
    /// This parameter's JSON-schema property: the type, the sentence, and
    /// the band only when it is shown.
    fileprivate var property: [String: any Sendable] {
        var property: [String: any Sendable] = [
            "type": kind.jsonType,
            "description": description
        ]
        if let range, showsRange {
            property["minimum"] = Self.bound(range.lowerBound)
            property["maximum"] = Self.bound(range.upperBound)
        }
        return property
    }

    /// A bound as the model reads it: a whole number WHOLE (`20`, not
    /// `20.0`) — the spelling `ToolValue.plain` uses in the refusal
    /// sentence, so the model meets one spelling of the band whichever
    /// way it meets it — and a decimal as itself.
    private static func bound(_ number: Double) -> any Sendable {
        if let whole = Int(exactly: number) { return whole }
        return number
    }
}

extension MultiModalKit.ToolParameter.Kind {
    /// The JSON-schema word for the kind — the same four the Apple mind's
    /// schema uses, so one declaration reads the same to both minds.
    var jsonType: String {
        switch self {
        case .string: "string"
        case .number: "number"
        case .integer: "integer"
        case .boolean: "boolean"
        }
    }
}

extension ToolTable {
    /// The specs to hand `UserInput(chat:tools:)` — and `nil`, not `[]`,
    /// when the table is empty. The distinction is AC-227's whole Mac
    /// half: the template branches on `if tools`, so a generator with no
    /// tools must render EXACTLY the prompt it rendered before 4w, and
    /// an empty array would still be a value. `nil` is "no tools were
    /// given", which is the truth.
    var toolSpecs: [ToolSpec]? {
        isEmpty ? nil : tools.map(\.toolSpec)
    }
}

// MARK: - from the vendor's call to the seam's request

extension ToolCallRequest {
    /// The vendor's parsed call, its arguments mapped onto the contract's
    /// values by `ToolValue.init(json:)`. The vendor's optional call `id`
    /// is not carried, because the template this mind runs does not need
    /// one to pair a call with its result (it pairs by order:
    /// `<tool_call>` then `<tool_response>`).
    init(vendor call: ToolCall) {
        self.init(name: call.function.name,
                  arguments: ToolArguments(call.function.arguments.mapValues(ToolValue.init(json:))))
    }
}

// MARK: - the vendor's JSON and the contract's value (4z, AC-269's MLX half)

extension ToolValue {
    /// One `JSONValue` as the contract's value, BY KIND — so a number the
    /// model wrote as a number arrives as `.number` and the door's count
    /// of coercions (F-8 C) is honest: a `"84"` it wrote as text is a
    /// coercion, an `84` it wrote as a number is not. (4w flattened every
    /// argument to text and the tool parsed it; D-101's spike, replaced
    /// here under F-1 = A.)
    ///
    /// - the vendor's `.int` and `.double` are ONE value, `.number`
    ///   (F-13 b): `84` here and `84.0` on the Apple mind are the same
    ///   `ToolValue`, so one literal in a test matches both minds;
    /// - a string, a bool and `null` are themselves;
    /// - an array or an object is carried as `.array` / `.object`, not
    ///   folded into text (F-13 i): the door refuses it for a scalar
    ///   parameter and names what it saw ("a list", "an object").
    init(json value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .boolean(flag)
        case .int(let whole): self = .number(Double(whole))
        case .double(let number): self = .number(number)
        case .string(let text): self = .string(text)
        case .array(let items): self = .array(items.map(ToolValue.init(json:)))
        case .object(let fields): self = .object(fields.mapValues(ToolValue.init(json:)))
        }
    }

    /// The way back, for the prompt's own record of a call (the
    /// assistant turn the next round reads, `LocalMind+Tools`): a whole
    /// number is written whole — `84`, as the model wrote it — the rest
    /// are themselves, and a container recurses.
    var json: JSONValue {
        switch self {
        case .null: .null
        case .boolean(let flag): .bool(flag)
        case .number(let number):
            if let whole = Int(exactly: number) { .int(whole) } else { .double(number) }
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(\.json))
        case .object(let fields): .object(fields.mapValues(\.json))
        }
    }
}

// MARK: - the template's closing tag inside a result (4z, AC-288, F-13 f: the escape at THIS seam)

/// A tool's answer goes back to the model INSIDE the template's
/// `<tool_response>…</tool_response>` block, so an answer that carries
/// the closing tag itself would end the block early and hand the model
/// whatever follows as if the template had written it. D-110 F-13 (f)
/// puts the escape HERE, at the MLX seam, not in the core door: the tag
/// is this chat template's word, and the core stays template-blind (the
/// Apple result is untouched). THE SHAPE: identity, until the escape
/// lands; `ToolResponseEscapeTests` is red until it does.
enum ToolResponseTag {
    static func escape(_ answer: String) -> String {
        answer
    }
}

// MARK: - the cap on rounds (AC-222's bound)

/// How many times ONE reply may go back to the model with a tool's
/// answer. A model that calls a tool, reads the answer, and calls again
/// forever must not spin the run — every round is a full prefill and
/// a generation, so an unbounded loop is a phone that never answers.
///
/// FOUR, and why: Aura's read is one call (F-3 = C); a read-then-write
/// is two; four leaves room for a model that re-asks after a failure
/// (F-4 = B) without letting a confused one run the battery down. It is
/// a spike number, stated so the contract milestone can price it and
/// move it. Past the cap the reply ends `.failed(.engine(…))` with the
/// sentence below — the same honest catch-all every other engine fault
/// rides (D-103 F-3 = A); whether "too many tool rounds" earns its own
/// `ReplyFailure` case is the contract's to rule (§170), not this
/// spike's, so the words are pinned here where a test can name them.
enum ToolRounds {
    static let cap = 4

    /// The failure a run reports when the model asks for a tool AGAIN
    /// after `cap` rounds have already been answered.
    static var exceeded: ReplyFailure {
        .engine("the model asked for a tool in more than \(cap) rounds of one reply")
    }
}
