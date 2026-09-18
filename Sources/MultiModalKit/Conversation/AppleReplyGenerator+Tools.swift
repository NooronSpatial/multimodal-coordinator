// THE APPLE MIND'S TOOL ADAPTER (4w piece 3, AC-223; 4z piece 3, AC-269,
// AC-270, AC-275, AC-276, AC-289 — D-110 F-1 = A, F-2 = A, F-4 = B,
// F-11 = B, F-13 (d)).
//
// The vendor's shape and ours, side by side:
//
//     ours (ReplyTool)                 the vendor's (protocol Tool)
//     ─────────────────                ────────────────────────────
//     name: String                     name: String
//     description: String              description: String
//     parameters: [ToolParameter]      parameters: GenerationSchema   ← built HERE, at run time
//     body(ToolArguments) -> String    call(arguments: Arguments) -> Output
//                                      Arguments = GeneratedContent   ← the vendor's typed tree
//
// The vendor EXECUTES the tool itself, inside `streamResponse`, and then
// continues the reply — which is exactly why 4w's F-1 = B was ruled: the
// run never sees a call, the seam stays "tokens, then one terminal", and
// this file's whole job is to make ONE `ReplyTool` look like ONE vendor
// `Tool`. Since 4z the tool has PARAMETERS, so this file also does the
// two translations the spike deferred: the app's declaration becomes
// the schema the model is SHOWN, and the model's typed answer becomes
// the `ToolArguments` the door reads. The door itself — strip, check,
// band, flag, shield, cap — is `ToolTable.invoke`, shared with every
// mind; nothing here judges an argument.

import FoundationModels

// MARK: - the arguments of a tool that takes none (the spike's schema)

/// The schema for a tool with NO parameters — the spike's one tool
/// (4w, F-3 = C), and AC-270's "unchanged" case. `@Generable` so the
/// vendor derives an object schema with no properties from it; a tool
/// with parameters does not use this — its schema is built from the
/// `ReplyTool` at run time (`AppleToolAdapter.schema(for:)`).
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct AppleToolNoArguments {}

// MARK: - the adapter

/// One `ReplyTool`, wearing the vendor's protocol, for ONE call: it
/// carries the call's confirmed names (F-10 B-ii) because the vendor
/// runs the tool where no call context of ours can reach. Internal so
/// the unit tests can instantiate it and call it directly (the scripted
/// snapshot source cannot execute a vendor tool, so the adapter's shape
/// is proved on the adapter, not through the seam).
@available(macOS 26.0, iOS 26.0, *)
struct AppleToolAdapter: Tool {
    /// The vendor's own typed tree. `GeneratedContent` is what the model
    /// writes, read by KIND (number, string, bool, null, array, object);
    /// declaring it as the `Arguments` type is what lets the schema be
    /// built at run time instead of derived from a Swift struct.
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: ReplyTool
    /// The tool names the person has said yes to, for this call only
    /// (`GenerationOptions.confirmedTools`, F-10 B-ii).
    let confirmed: Set<String>
    /// The schema the model is SHOWN, built once per adapter from the
    /// declaration (AC-270).
    let parameters: GenerationSchema

    /// Throws only what the vendor throws for a declaration it cannot
    /// render (`GenerationSchema.SchemaError`, e.g. `duplicateProperty`).
    /// The library's own check runs first, where the table is handed
    /// over (F-13 d: `ToolTable.checkDeclarations`), so a validated table
    /// never reaches this throw; it stays as the vendor's second line.
    init(_ tool: ReplyTool, confirmed: Set<String> = []) throws {
        self.tool = tool
        self.confirmed = confirmed
        self.parameters = try Self.schema(for: tool)
    }

    /// The model's name for it — `ReplyTool.name`, verbatim. The
    /// vendor's default would be the TYPE's name, which is the same
    /// word for every tool in the table.
    var name: String { tool.name }
    /// The words the model is shown — the app's (D-027), verbatim.
    var description: String { tool.description }

    /// The declaration, in the vendor's words (AC-270, F-11 B's "shown"
    /// switch). SHAPE ONLY in this commit: every tool shows the spike's
    /// empty schema — the rows for a tool with parameters are red on
    /// purpose until the next commit renders them.
    static func schema(for tool: ReplyTool) throws -> GenerationSchema {
        AppleToolNoArguments.generationSchema
    }

    /// The vendor calls this from inside the session while the reply is
    /// being generated; the answer goes back to the MODEL, not to us.
    /// SHAPE ONLY in this commit: the arguments are not read and a
    /// refusal is still rethrown (4w's ending) — AC-269's conversion rows
    /// and AC-276's F-4 = B rows are red until the next commit.
    func call(arguments: GeneratedContent) async throws -> String {
        let outcome = await ToolTable([tool]).invoke(tool.name, arguments: .empty, confirmed: confirmed)
        try Task.checkCancellation()
        return try outcome.result.get()
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleToolAdapter {
    /// The table, as the vendor's list — one adapter per `ReplyTool`, in
    /// the table's order, and `[]` for `.empty`. `[]` is the vendor's
    /// own default for `tools:`, so the session built from it is EXACTLY
    /// the one built before 4w (AC-227: a mind with no tools pays nothing
    /// for this file — measured, see `AppleReplyGenerator.session`).
    static func adapters(for table: ToolTable, confirmed: Set<String> = []) throws -> [any Tool] {
        try table.tools.map { try AppleToolAdapter($0, confirmed: confirmed) }
    }
}

// MARK: - the model's typed answer, in the door's words (AC-269)

extension ToolValue {
    /// The vendor's `GeneratedContent`, read by KIND into the contract's
    /// value: one number case (F-13 b), strings, booleans, null, and the
    /// two structured shapes the door refuses for a scalar parameter
    /// (F-13 i). SHAPE ONLY in this commit: everything reads as `.null`.
    @available(macOS 26.0, iOS 26.0, *)
    init(_ content: GeneratedContent) {
        self = .null
    }
}

extension ToolArguments {
    /// The model's whole answer — a structure — as the door's arguments.
    /// Anything that is not a structure is no arguments at all (`.empty`).
    @available(macOS 26.0, iOS 26.0, *)
    init(_ content: GeneratedContent) {
        self = .empty
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
    /// Since 4z (F-4 = B) the adapter does not throw for a tool of ours:
    /// a refusal, a thrown body, a missing yes — all go back to the model
    /// as the door's sentence, and the reply goes on. What can still
    /// reach this fold is the vendor's own error for the ONE throw the
    /// adapter keeps: `CancellationError` after a barge (the ticket's
    /// belt in `call`). The fold stays for that, and for a vendor that
    /// throws on its own.
    static func toolFailure(from error: LanguageModelSession.ToolCallError) -> ToolCallFailure {
        // A value the door typed is carried whole, not wrapped a second
        // time into `tool 'x' failed: tool 'x' failed: …`.
        if let typed = error.underlyingError as? ToolCallFailure { return typed }
        return ToolCallFailure(tool: error.tool.name,
                               reason: .threw(String(describing: error.underlyingError)))
    }
}
