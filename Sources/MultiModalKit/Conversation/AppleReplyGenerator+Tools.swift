// THE APPLE MIND'S TOOL ADAPTER (4w piece 3 → 4z, AC-223, AC-269, AC-271,
// AC-273; D-101 F-1 = B, D-108 F-4 = B).
//
// The vendor's shape and ours, side by side:
//
//     ours (ReplyTool)                     the vendor's (protocol Tool)
//     ─────────────────                    ────────────────────────────
//     name: String                         name: String
//     description: String                  description: String
//     parameters: [ToolParameter]          parameters: GenerationSchema   ← built HERE, at run time
//     call(ToolArguments) -> String        call(arguments: Arguments) -> Output
//                                          Arguments = GeneratedContent   ← read HERE, by kind
//
// The vendor EXECUTES the tool itself, inside `streamResponse`, and then
// continues the reply — which is exactly why F-1 = B was ruled: the run
// never sees a call, the seam stays "tokens, then one terminal", and
// this file's whole job is to make ONE `ReplyTool` look like ONE vendor
// `Tool`. There is no loop of ours here and no second lookup: the
// framework matches names against the tools it was handed.
//
// WHAT 4z CHANGED. The spike showed the model an EMPTY schema and handed
// the tool `[:]`. Now the schema is built from the app's `ToolParameter`s
// through `DynamicGenerationSchema` — checked against the SDK's own
// interface before it was written (SPEC §192) — and the model's
// arguments arrive as `GeneratedContent`, which is `Generable` and so a
// legal `Arguments`, and are read by their `kind` into `ToolArguments`.
// And a tool that cannot run is ANSWERED, not thrown (F-4 = B): the
// model reads the same sentence the MLX run hands its model, and the
// reply goes on.

import FoundationModels

// MARK: - the adapter

/// One `ReplyTool`, wearing the vendor's protocol. Internal so the unit
/// tests can instantiate it and call it directly (the scripted snapshot
/// source cannot execute a vendor tool, so the adapter's shape is
/// proved on the adapter, not through the seam).
@available(macOS 26.0, iOS 26.0, *)
struct AppleToolAdapter: Tool {
    /// The vendor's own untyped content, so a schema built at run time
    /// has a matching argument type without a compile-time struct.
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: ReplyTool

    /// The schema the model is shown (AC-269), built once from the
    /// parameters. `GenerationSchema(root:dependencies:)` throws only for
    /// a malformed dynamic schema — for four scalar kinds under unique
    /// names it cannot — so the fallback is the spike's empty schema,
    /// which never traps and, if ever reached, makes the table refuse
    /// every required argument in words rather than crash an app.
    let parameters: GenerationSchema

    init(_ tool: ReplyTool) {
        self.tool = tool
        self.parameters = (try? GenerationSchema(root: Self.dynamicSchema(for: tool), dependencies: []))
            ?? AppleToolNoArguments.generationSchema
    }

    /// The model's name for it — `ReplyTool.name`, verbatim. The
    /// vendor's default would be the TYPE's name, which is the same
    /// word for every tool in the table.
    var name: String { tool.name }

    /// The words the model is shown — the app's (D-027), verbatim.
    var description: String { tool.description }

    /// The vendor calls this from inside the session while the reply is
    /// being generated; the answer goes back to the MODEL, not to us.
    ///
    /// Three things happen here and nowhere else on this mind:
    /// 1. the vendor's content is read into `ToolArguments` by kind;
    /// 2. `ReplyTool.invoke` checks the declaration, runs the body, and
    ///    folds a throw — the one rule every mind shares;
    /// 3. a failure is RETURNED as the tool's output (F-4 = B), so the
    ///    model reads "tool 'x' cannot run: …" or "tool 'x' failed: …"
    ///    and recovers in words, exactly as the MLX run's model does.
    ///
    /// THE REENTRANCY LAW (§4.1), applied at the one `await` this file
    /// owns: a barge may have retired the run while the tool was busy.
    /// The run's `retired` latch is the PRIMARY guard — once `cancel()`
    /// has finished the output stream, nothing the framework produces
    /// afterwards reaches anyone (AC-226's rule). This check is the belt:
    /// when the vendor runs the tool inside the cancelled task tree, a
    /// late answer is thrown away HERE, before the vendor can spend a
    /// prefill feeding it to a model nobody is listening to. The tool
    /// itself ran to its end (F-5 = A): a write is not un-written.
    func call(arguments: GeneratedContent) async throws -> String {
        let outcome = await tool.invoke(Self.toolArguments(from: arguments))
        try Task.checkCancellation()
        switch outcome {
        case .success(let answer): return answer
        case .failure(let failure): return failure.description
        }
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

    // MARK: the schema (AC-269)

    /// One object whose properties are the parameters: the kind's own
    /// `Generable` scalar, the app's description, and `isOptional` for a
    /// parameter the model may leave out.
    static func dynamicSchema(for tool: ReplyTool) -> DynamicGenerationSchema {
        DynamicGenerationSchema(
            name: tool.name,
            description: tool.description,
            properties: tool.parameters.map { parameter in
                DynamicGenerationSchema.Property(
                    name: parameter.name,
                    description: parameter.description,
                    schema: scalarSchema(for: parameter.kind),
                    isOptional: !parameter.isRequired)
            })
    }

    private static func scalarSchema(for kind: ToolParameter.Kind) -> DynamicGenerationSchema {
        switch kind {
        case .string: DynamicGenerationSchema(type: String.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .boolean: DynamicGenerationSchema(type: Bool.self)
        }
    }

    // MARK: the arguments (AC-271)

    /// The vendor's content, read by kind. The vendor has ONE number kind
    /// (`Double`), so an `integer` parameter arrives as `.number(3.0)`
    /// and `ToolArguments.integer` reads it as 3. A nested array or
    /// structure — outside the contract (§194) — arrives as its JSON
    /// text, the same rule as the MLX mind's. Anything that is not a
    /// structure at the top (the vendor generating a bare scalar for a
    /// tool with no properties) is no arguments.
    static func toolArguments(from content: GeneratedContent) -> ToolArguments {
        guard case .structure(let properties, _) = content.kind else { return .none }
        return ToolArguments(properties.mapValues(toolValue))
    }

    private static func toolValue(_ content: GeneratedContent) -> ToolValue {
        switch content.kind {
        case .null: .null
        case .bool(let flag): .boolean(flag)
        case .number(let number): .number(number)
        case .string(let text): .string(text)
        case .array, .structure: .string(content.jsonString)
        // The vendor's enum is not frozen: a kind added by a future SDK
        // arrives as its JSON text rather than a crash or a silent drop.
        @unknown default: .string(content.jsonString)
        }
    }
}

// MARK: - the empty schema (the spike's, kept as the fallback)

/// The schema a tool with no parameters showed in 4w, and the fallback
/// the initializer names above. `@Generable` because the vendor derives
/// a schema from a type; an empty struct yields an object with no
/// properties, which is the honest description of a read that takes
/// nothing.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct AppleToolNoArguments {}

// MARK: - the vendor's own tool error, in the seam's words (the belt)

@available(macOS 26.0, iOS 26.0, *)
extension AppleReplyRun {
    /// The vendor's `ToolCallError` — thrown out of `streamResponse` when
    /// a tool's `call` throws — folded into the SAME `ToolCallFailure`
    /// the scripted and MLX minds produce.
    ///
    /// Under F-4 = B (D-108) `AppleToolAdapter.call` never throws for a
    /// tool of ours, so the vendor never builds this error from one. It
    /// stays as the belt for whatever else the vendor may raise under
    /// that type: if the stream ever ends with it, the run reports the
    /// agreed words rather than the vendor's.
    ///
    /// Checked against the interface: `GenerationError` has NO tool case;
    /// the tool failure is its own error type beside it, carrying `tool`
    /// and `underlyingError`. The words are `String(describing:
    /// underlyingError)`, which is what `ReplyTool.invoke` writes for the
    /// other minds — the same error gives the same sentence.
    static func toolFailure(from error: LanguageModelSession.ToolCallError) -> ToolCallFailure {
        ToolCallFailure(tool: error.tool.name,
                        reason: .threw(String(describing: error.underlyingError)))
    }
}
