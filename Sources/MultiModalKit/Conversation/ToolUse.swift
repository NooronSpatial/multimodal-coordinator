// ONE USE OF A TOOL, AS A RECORD (5b — D-116 F-3 A, D-117 F-8 A,
// D-119 F-14 A).
//
// Before 5b nothing outside a mind could hear that a tool ran: the Apple
// vendor runs it inside its own stream, and the seam carried tokens and
// one ending. A transcript rebuilt from the memory then carried the
// tool's sentence as the assistant's own prose — and the phone heard
// "Logged 12 kg" from a turn in which no tool ran (SPEC §207).
//
//     the mind ── .token … .toolRan(ToolUse) … .token … .finished ──▶ the coordinator
//                              │                                          │
//                              └──────── kept on the turn ──▶ ConversationTurn.tools
//                                                                         │
//                              a re-seed replays it as a TYPED tool call ◀┘
//                              and its output, never as prose

/// One use of a tool during a reply: what the model called, with what,
/// and what the door did.
///
/// The mind sends it as `ReplyUpdate.toolRan` the moment the tool has
/// run; the coordinator keeps it on the turn (`ConversationTurn.tools`);
/// a re-seed replays it as a tool call and its output. Refusals are uses
/// too — a missing yes, a bad argument: the model was told something, and
/// what it was told is part of what it said and did.
public struct ToolUse: Sendable, Equatable {
    /// The tool's name, as the model called it.
    public let name: String
    /// The model's arguments as the door READ them — by kind, before its
    /// checks: what the model wrote, so a replay shows the model its own
    /// call. What the body received (extras stripped, text read as a
    /// number) is counted on `outcome`.
    public let arguments: ToolArguments
    /// What the door did — the body's answer, or why it refused, and the
    /// counts it kept on the way. `outcome.wordsForModel` is what the
    /// model was told.
    public let outcome: ToolCallOutcome

    public init(name: String, arguments: ToolArguments, outcome: ToolCallOutcome) {
        self.name = name
        self.arguments = arguments
        self.outcome = outcome
    }

    /// What this use costs a replay, in characters: its name, its
    /// arguments as JSON, and the words the model was given. It counts
    /// against `ConversationMemory.maxCharacters` because D-092 priced the
    /// memory by the character, and a replayed tool output is characters
    /// — up to `ToolTable.answerCap` of them (D-119).
    public var characters: Int {
        name.count + arguments.json.count + outcome.wordsForModel.count
    }
}

// MARK: - arguments as the replay writes them

extension ToolArguments {
    /// The arguments as one JSON object, keys sorted — the shape a replay
    /// hands the vendor, rendered here only to COUNT it.
    var json: String { ToolValue.object(values).json }
}

extension ToolValue {
    /// This value as JSON, object keys sorted so one value has one
    /// rendering.
    var json: String {
        switch self {
        case .string(let text): Self.quoted(text)
        case .number(let number): Self.plain(number)
        case .boolean(let flag): flag ? "true" : "false"
        case .null: "null"
        case .array(let elements): "[" + elements.map(\.json).joined(separator: ",") + "]"
        case .object(let fields):
            "{" + fields.sorted { $0.key < $1.key }
                .map { Self.quoted($0.key) + ":" + $0.value.json }
                .joined(separator: ",") + "}"
        }
    }

    /// A JSON string literal: the two characters JSON cannot hold bare
    /// are escaped, the rest as written.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
