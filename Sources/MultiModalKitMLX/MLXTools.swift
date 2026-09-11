import Foundation
import MLXLMCommon
import MultiModalKit

// THE LOCAL MIND'S SIDE OF A TOOL CALL (4w, SPEC §169/1–2, AC-222; D-101).
//
// Everything here is a pure function or a plain value — a `ReplyTool`
// in, the vendor's spec out; the vendor's parsed call in, the seam's
// flat request out; a count in, a refusal out. None of it needs
// weights, a GPU or a metallib, which is why it lives apart from
// `LocalMind.swift`, the same split `MLXGeneration.swift` made for 4v:
// the live path is proven by gated tests that need all three, and the
// RULES it applies are proven here on every machine.
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

/// One call the model asked for, in the seam's flat shape (§170: the
/// spike's `ReplyTool` takes `[String: String]`). Built from the
/// vendor's `ToolCall` by `init(vendor:)`; built by hand by a scripted
/// source, so the run's arm is proven without a model.
struct ToolCallRequest: Sendable, Equatable {
    let name: String
    let arguments: [String: String]

    init(name: String, arguments: [String: String] = [:]) {
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

// MARK: - the spec the model is shown (AC-222)

extension ReplyTool {
    /// The `ToolSpec` the vendor renders into the chat template — the
    /// `<tools>` block the model reads before the question.
    ///
    /// A NO-ARGUMENT READ, THIS SPIKE (§170): `parameters` is an empty
    /// object, because Aura's session read takes none (F-3 = C) and
    /// `ReplyTool` has no schema to render. The contract milestone
    /// widens this in one place: typed arguments — a schema the model is
    /// shown, so the Apple mind can build its `GenerationSchema` and
    /// this template can render real parameters. Nothing else here is
    /// expected to change: the outer shape is the one every chat
    /// template of this family reads.
    var toolSpec: ToolSpec {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": [String: any Sendable]()
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
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
    /// The vendor's parsed call, flattened to the spike's `[String:
    /// String]`. Every `JSONValue` becomes text by `flatten(_:)`; the
    /// vendor's optional call `id` is not carried, because the template
    /// this mind runs does not need one to pair a call with its result
    /// (it pairs by order: `<tool_call>` then `<tool_response>`).
    init(vendor call: ToolCall) {
        self.init(name: call.function.name,
                  arguments: call.function.arguments.mapValues(Self.flatten))
    }

    /// One `JSONValue` as a string, LOSSLESSLY for the scalars a tool
    /// argument is likely to be, and as JSON text for the rest:
    /// - a string is itself, unquoted (`"40"` → `40`);
    /// - an int, a double, a bool print the way Swift prints them;
    /// - `null` is the word `null`;
    /// - an array or an object is its JSON, keys sorted, so the same
    ///   value always flattens to the same bytes.
    ///
    /// A pure function, tested against fixtures (`MLXToolTests`). The
    /// contract milestone replaces this with typed arguments; until
    /// then a tool that wants a number parses the text it is given.
    static func flatten(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let bool): bool ? "true" : "false"
        case .int(let int): String(int)
        case .double(let double): String(double)
        case .string(let string): string
        case .array, .object: json(value)
        }
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            // `JSONValue` is `Codable` over plain JSON scalars; encoding
            // cannot fail for a value the vendor's parser produced. The
            // fallback is named rather than trapped on, because a tool
            // argument is not worth a crash.
            return "\(value)"
        }
        return text
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
