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
// the framework matches names against the tools it was handed. What it
// does for a name no tool has is the vendor's and NOT MEASURED HERE —
// SPEC §172's F-4 reads it as "tells the model and lets it recover in
// words", which is the policy `ToolTable.call` writes for the other
// minds; no test on this Mac can reach that path (the model was not
// ready — see `AppleToolLiveTests`), so this file adds no lookup of its
// own and makes no promise about the vendor's.

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
    /// A THROW IS LET THROUGH ON PURPOSE, FOR NOW: the vendor wraps it in
    /// its `ToolCallError` and ends the response, and the run reports
    /// `.failed`. Catching it here and returning the failure sentence as
    /// the `Output` — so the model is told and recovers in words — is the
    /// other half of an open fork (see `AppleReplyRun.toolFailure`), and
    /// it is Ryad's to rule, not this file's.
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
    /// the table's order, and `[]` for `.empty`. `[]` is the vendor's
    /// own default for `tools:`, so the session built from it is EXACTLY
    /// the one built before 4w (AC-227: a mind with no tools pays nothing
    /// for this file — measured, see `AppleReplyGenerator.session`).
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
    /// AN OPEN FORK, NOT RULED HERE (the 4w review's blocking finding on
    /// this piece). When a tool's `call` throws, the vendor ends the
    /// response with this error — it does not tell the model on its own.
    /// But the ADAPTER could: `Tool.Output` is any `PromptRepresentable`,
    /// `String` is one, so `AppleToolAdapter.call` could `catch` and
    /// return `ToolCallFailure(…).description` as the tool's output, and
    /// the model would read the sentence and recover in words. The
    /// interface allows both endings; a first draft of this comment
    /// claimed it forbade the second, which was wrong. So the fork:
    ///
    ///   A — propagate the throw (TODAY'S CODE, kept until ruled): the
    ///       run ends `.failed(.engine("tool 'x' failed: …"))`, the
    ///       scripted mind's `.failsReply` shape — a hard failure a
    ///       caller can count, and the person hears nothing.
    ///   B — catch in the adapter and answer the model with the sentence:
    ///       the run ends `.finished` with a spoken "I couldn't read
    ///       that", the scripted mind's `.speaks` shape — which is what
    ///       the MLX run does for BOTH failure ways, and the words of
    ///       AC-225 ("the mind is told, the reply says so").
    ///
    /// Until Ryad rules it the two real minds END AC-225 DIFFERENTLY for
    /// the same throwing tool, and a caller counting outcomes must know
    /// that. D-101's F-4 = B does not settle it: F-4 names the MLX run's
    /// unknown-name case only. This function stays under either ruling —
    /// it is the fold for the error the vendor can raise regardless of
    /// what the adapter does — and the live test (`AppleToolLiveTests`,
    /// AC-225) pins the interim ending A until the ruling changes it.
    static func toolFailure(from error: LanguageModelSession.ToolCallError) -> ToolCallFailure {
        ToolCallFailure(tool: error.tool.name,
                        reason: .threw(String(describing: error.underlyingError)))
    }
}
