// THE TOOL A MIND MAY CALL — the spike's type (4w, SPEC §168–§172, D-101).
//
// SPIKE-SHAPED, ON PURPOSE. §170 says a tool CONTRACT is a non-goal: the
// contract is what this spike INFORMS, and designing it here would be
// the guess 4p refused. So this file holds the SMALLEST thing both real
// minds can consume — a name, a description, and a function — and
// nothing that would have to be argued: no capability system, no
// permission, no registry. Every field below was checked against what
// the two real minds already accept, and the contract milestone is
// expected to replace this type, not to grow it.
//
// THE PROMISE THAT SHAPES EVERYTHING (F-1 = B, D-101): the run executes
// the tool ITSELF. `ReplyUpdate` stays `.token / .finished / .failed`,
// the coordinator never sees a call, and "tokens, then one terminal" is
// as true with a tool as without one (§172c). A generator is HANDED its
// tools at construction (F-2 = A) — the coordinator neither holds them
// nor passes them, so it can never learn a `switch` over them (§3's
// registration rule).

// MARK: - one tool

/// One thing a reply may ask for while it is being generated (4w, §168).
///
/// WHY IT EXISTS: the reply seam carried text and nothing else, and both
/// real minds can already call something — Apple's through its own
/// `Tool` protocol, MLX's through a `.toolCall` event its template
/// renders and its token loop emits. What the library needed was ONE
/// value an app can hand to EITHER mind, so a throwaway read ("what is
/// today's session?", F-3 = C) can be rehearsed on both and measured.
///
/// WHY IT IS THIS SMALL (§170): the arguments are `[String: String]`.
/// A no-argument read needs no more, and both minds can produce it —
/// MLX's parsed arguments are a JSON dictionary this can be read out of,
/// Apple's arrive typed and can be rendered into it. The contract
/// milestone will have to widen this in at least two places: typed
/// arguments (a schema the model is shown, so the Apple mind can build
/// its `GenerationSchema` and the MLX template can render parameters),
/// and a typed result (today a `String`, which is what both minds feed
/// back to the model verbatim). Neither is decided here.
///
/// `call` may throw. What the run does with a throw is the run's — the
/// spike's minds are told (F-4 = B) and the failure is a typed, countable
/// value (`ToolCallFailure`, AC-225), never a crash.
public struct ReplyTool: Sendable {
    /// The name the model uses to ask for it. Exact-match, case-sensitive:
    /// one lookup rule for both minds (`ToolTable`).
    public let name: String
    /// What the model is told the tool does — the text both minds render
    /// into their prompt or spec. The words are the APP's (D-027): this
    /// library ships no prompt.
    public let description: String
    /// The tool itself. Runs INSIDE the reply (F-1 = B), so it must be
    /// safe to call from any task and must not touch the coordinator.
    public let call: @Sendable ([String: String]) async throws -> String

    public init(name: String,
                description: String,
                call: @escaping @Sendable ([String: String]) async throws -> String) {
        self.name = name
        self.description = description
        self.call = call
    }
}

// MARK: - why a call failed (AC-225)

/// A tool call that did not produce an answer — typed, so a caller can
/// COUNT it, and `Equatable`, so a test can name the exact value.
///
/// It is a struct beside `ReplyFailure`, not a case in it, by the same
/// non-goal (§170): whether a failed tool is its own `ReplyFailure` case
/// is the contract's to rule, and adding a case today would reach every
/// exhaustive switch a caller already has. Until then a run that gives
/// up on a failed call reports `.failed(.engine(failure.description))` —
/// the words are here, and this value is what produced them.
public struct ToolCallFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// What went wrong, in the two ways a call can.
    public enum Reason: Sendable, Equatable {
        /// The model asked for a name no tool has (F-4 = B's case).
        case unknownTool
        /// The tool ran and threw; the string is the error's own words.
        case threw(String)
    }

    /// The name the model asked for — even when nothing answers to it.
    public let tool: String
    public let reason: Reason

    public init(tool: String, reason: Reason) {
        self.tool = tool
        self.reason = reason
    }

    /// The sentence a run may hand BACK TO THE MODEL (F-4 = B), and the
    /// one that rides `.failed(.engine(_))` when the run gives up instead.
    public var description: String {
        switch reason {
        case .unknownTool:
            "no tool named '\(tool)'"
        case .threw(let words):
            "tool '\(tool)' failed: \(words)"
        }
    }
}

// MARK: - the tools a mind was given (F-2 = A)

/// The tools ONE generator holds — handed to it at construction and never
/// to the coordinator (F-2 = A, D-101): tools are policy the app grants,
/// so they live with the mind the app configured.
///
/// It exists so both minds share ONE lookup rule instead of each writing
/// its own `first(where:)`. The rule: exact name, first match wins, and a
/// name no tool has returns `nil` — the table does not decide what that
/// means. Under F-4 = B the run answers the model with
/// `ToolCallFailure(tool:reason: .unknownTool).description` and lets it
/// recover in words; `call(_:arguments:)` below is that rule written
/// once, so a mind that wants it does not re-derive it.
public struct ToolTable: Sendable {
    public let tools: [ReplyTool]

    public init(_ tools: [ReplyTool] = []) {
        self.tools = tools
    }

    /// No tools at all — the shape every generator had before 4w.
    public static let empty = ToolTable()

    public var isEmpty: Bool { tools.isEmpty }

    /// THE lookup: exact name, first match, `nil` for a name no tool has.
    public subscript(name: String) -> ReplyTool? {
        tools.first { $0.name == name }
    }

    /// Looks the name up and runs the tool, folding both ways a call can
    /// fail into one typed value — the whole of what a run must do with a
    /// model's request, so the MLX mind and the scripted mind do it the
    /// same way. (The Apple mind's framework does its own lookup and
    /// calls `ReplyTool.call` directly through its `Tool` adapter.)
    public func call(_ name: String,
                     arguments: [String: String]) async -> Result<String, ToolCallFailure> {
        guard let tool = self[name] else {
            return .failure(ToolCallFailure(tool: name, reason: .unknownTool))
        }
        do {
            return .success(try await tool.call(arguments))
        } catch {
            return .failure(ToolCallFailure(tool: name, reason: .threw(String(describing: error))))
        }
    }
}
