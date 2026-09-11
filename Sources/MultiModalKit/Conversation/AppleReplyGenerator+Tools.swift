// THE APPLE MIND'S TOOL ADAPTER (4w piece 3, AC-223, D-101 F-1 = B, F-2 = A).
//
// The vendor's shape and ours, side by side:
//
//     ours (ReplyTool)                 the vendor's (protocol Tool)
//     ─────────────────                ────────────────────────────
//     name: String                     name: String
//     description: String              description: String
//     call([String: String]) -> String call(arguments: Arguments) -> Output
//                                      parameters: GenerationSchema   ← derived from Arguments
//
// The vendor EXECUTES the tool itself, inside `streamResponse`, and then
// continues the reply — which is exactly why F-1 = B was ruled: the run
// never sees a call, the seam stays "tokens, then one terminal", and
// this file's whole job is to make ONE `ReplyTool` look like ONE vendor
// `Tool`. There is no loop of ours here and no second lookup (F-4 = B):
// the framework matches names against the tools it was handed and, for
// a name no tool has, tells the model so and lets it recover in words —
// the same policy `ToolTable.call` writes for the other minds.

import FoundationModels

// MARK: - the arguments (none, this spike)

/// What the model may pass to a spike tool: NOTHING. The spike's one
/// tool is a no-argument read ("what is today's session?", F-3 = C), and
/// `ReplyTool.call` takes `[String: String]`, so an empty dictionary is
/// what the tool receives (SPEC §170: arguments are the contract's to
/// widen).
///
/// It is `@Generable` because the vendor derives `Tool.parameters` — the
/// JSON schema the model is SHOWN — from the `Arguments` type, and
/// refuses a bare `String`/`Int`/… with a compile-time "use a
/// `@Generable` struct instead". An empty struct yields a schema with no
/// properties, which is the honest description of a read that takes
/// nothing. WHAT THE CONTRACT WIDENS: a tool with real parameters needs
/// a schema built from the `ReplyTool` (the vendor's
/// `GenerationSchema(type:properties:)` is public, so it can be built by
/// hand at runtime) and the typed `GeneratedContent` rendered into the
/// `[String: String]` the tool takes. Neither is decided here (§170).
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct AppleToolNoArguments {}

// MARK: - the adapter

/// One `ReplyTool`, wearing the vendor's protocol. Internal so the unit
/// tests can instantiate it and call it directly (the scripted snapshot
/// source cannot execute a vendor tool, so the adapter's shape is
/// proved on the adapter, not through the seam).
@available(macOS 26.0, iOS 26.0, *)
struct AppleToolAdapter: Tool {
    typealias Arguments = AppleToolNoArguments
    typealias Output = String

    let tool: ReplyTool

    init(_ tool: ReplyTool) { self.tool = tool }

    /// The model's name for it — `ReplyTool.name`, verbatim. The
    /// vendor's default would be the TYPE's name, which is the same
    /// word for every tool in the table.
    var name: String { tool.name }
    /// The words the model is shown — the app's (D-027), verbatim.
    var description: String { tool.description }

    /// The vendor calls this from inside the session while the reply is
    /// being generated; the answer goes back to the MODEL, not to us.
    ///
    /// THE REENTRANCY LAW (§4.1), applied at the one `await` this file
    /// owns: a barge may have retired the run while the tool was busy.
    /// The run's `retired` latch is the PRIMARY guard — once `cancel()`
    /// has finished the output stream, nothing the framework produces
    /// afterwards reaches anyone (AC-226's rule, the fourth use of the
    /// ticket doctrine). This check is the belt: when the vendor runs the
    /// tool inside the cancelled task tree (whether it does is the
    /// vendor's, not a promise this library can read from its
    /// interface), a late answer is thrown away HERE, before the vendor
    /// can spend a prefill feeding it to a model nobody is listening to.
    func call(arguments: AppleToolNoArguments) async throws -> String {
        let answer = try await tool.call([:])
        try Task.checkCancellation()
        return answer
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleToolAdapter {
    /// The table, as the vendor's list — one adapter per `ReplyTool`, in
    /// the table's order, and `[]` for `.empty`. The caller uses the
    /// emptiness to build EXACTLY the session it built before 4w
    /// (AC-227: a mind with no tools pays nothing for this file).
    static func adapters(for table: ToolTable) -> [any Tool] {
        table.tools.map { AppleToolAdapter($0) }
    }
}

// MARK: - a tool's throw, in the seam's words (AC-225)

@available(macOS 26.0, iOS 26.0, *)
extension AppleReplyRun {
    /// The vendor's `ToolCallError` — thrown out of `streamResponse` when
    /// a tool's `call` throws — folded into the SAME `ToolCallFailure`
    /// the scripted and MLX minds produce, so a caller counting failures
    /// reads one sentence from every mind: `tool 'x' failed: <words>`.
    ///
    /// Checked against the interface: `GenerationError` has NO tool case
    /// (its nine are context, assets, guardrail, guide, locale, decoding,
    /// rate, concurrency, refusal); the tool failure is its own error
    /// type beside it, carrying `tool` and `underlyingError`. The words
    /// are `String(describing: underlyingError)`, which is what
    /// `ToolTable.call` writes for the other minds — the same error
    /// gives the same sentence.
    ///
    /// READ FROM THE INTERFACE, NOT YET MEASURED: the vendor's shape says
    /// a thrown tool ENDS the response with this error rather than
    /// telling the model and letting it recover in words — there is no
    /// path in the interface by which a tool's throw becomes a
    /// `.toolOutput` entry. So the run's ending is `.failed(.engine(_))`,
    /// the scripted mind's `.failsReply` shape, not its `.speaks`. The
    /// live test (`AppleToolLiveTests`, AC-225) pins that claim against
    /// the real session; on the Mac this was written on the model
    /// answered `modelNotReady`, so the test is armed and the claim is
    /// the interface's until the day it runs.
    static func toolFailure(from error: LanguageModelSession.ToolCallError) -> ToolCallFailure {
        ToolCallFailure(tool: error.tool.name,
                        reason: .threw(String(describing: error.underlyingError)))
    }
}
