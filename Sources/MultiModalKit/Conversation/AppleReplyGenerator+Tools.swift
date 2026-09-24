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
// run never has to execute a call, and this file's whole job is to make
// ONE `ReplyTool` look like ONE vendor `Tool`. (Since 5b the run REPORTS
// each use after the fact — `ReplyUpdate.toolRan`, D-120 — so the stream
// is no longer "tokens, then one terminal"; who runs a tool is
// unchanged.) Since 4z the tool has PARAMETERS, so this file also does the
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

/// One `ReplyTool`, wearing the vendor's protocol. It holds the
/// DECLARATION — what the model is shown — and reads the body it runs and
/// the yes it honours from its `route`, because the vendor runs the tool
/// where no call context of ours can reach, and since 5b one session (so
/// one set of adapters) serves a whole conversation (see `ToolRoute`).
/// Internal so the unit tests can instantiate it and call it directly
/// (the scripted snapshot source cannot execute a vendor tool, so the
/// adapter's shape is proved on the adapter, not through the seam).
@available(macOS 26.0, iOS 26.0, *)
struct AppleToolAdapter: Tool {
    /// The vendor's own typed tree. `GeneratedContent` is what the model
    /// writes, read by KIND (number, string, bool, null, array, object);
    /// declaring it as the `Arguments` type is what lets the schema be
    /// built at run time instead of derived from a Swift struct.
    typealias Arguments = GeneratedContent
    typealias Output = String

    /// The declaration the model is shown: name, words, parameters.
    let tool: ReplyTool
    /// This answer's table (whose body runs) and this answer's yes
    /// (`GenerationOptions.confirmedTools`, F-10 B-ii) — read at the
    /// moment the model calls, never captured at birth.
    let route: ToolRoute
    /// The schema the model is SHOWN, built once per adapter from the
    /// declaration (AC-270).
    let parameters: GenerationSchema

    /// Throws only what the vendor throws for a declaration it cannot
    /// render (`GenerationSchema.SchemaError`, e.g. `duplicateProperty`).
    /// The library's own check runs first, where the table is handed
    /// over (F-13 d: `ToolTable.checkDeclarations`), so a validated table
    /// never reaches this throw; it stays as the vendor's second line.
    init(_ tool: ReplyTool, route: ToolRoute) throws {
        self.tool = tool
        self.route = route
        self.parameters = try Self.schema(for: tool)
    }

    /// One tool with one fixed yes — the adapter as 4w and 4z built it,
    /// for the tests that knock on a single adapter directly.
    init(_ tool: ReplyTool, confirmed: Set<String> = []) throws {
        try self.init(tool, route: ToolRoute(ToolTable([tool]), confirmed: confirmed))
    }

    /// The model's name for it — `ReplyTool.name`, verbatim. The
    /// vendor's default would be the TYPE's name, which is the same
    /// word for every tool in the table.
    var name: String { tool.name }
    /// The words the model is shown — the app's (D-027), verbatim.
    var description: String { tool.description }

    /// The declaration, in the vendor's words (AC-270): one property per
    /// `ToolParameter`, its kind as the vendor's type, the app's sentence
    /// as its description, `isOptional` from `isRequired`. A band rides
    /// in as the vendor's range guide ONLY when the declaration says
    /// `showsRange` (F-11 B's two switches: shown here, checked at the
    /// door regardless — a band shown under constrained decoding turns a
    /// catchable 0 into an uncatchable 75, so the app decides per
    /// parameter). A tool with no parameters shows the spike's schema,
    /// unchanged — the `@Generable` empty struct's, so 4w's measured
    /// plain path is byte-for-byte what it was (AC-270's last clause).
    ///
    /// The vendor's `GenerationSchema(root:dependencies:)` throws for a
    /// declaration it cannot render — two properties of one name is
    /// `SchemaError.duplicateProperty`. The library refuses that table
    /// earlier, where it is handed over (`ToolTable.checkDeclarations`,
    /// F-13 d), so this throw is the vendor's second line, never the
    /// first.
    static func schema(for tool: ReplyTool) throws -> GenerationSchema {
        guard !tool.parameters.isEmpty else { return AppleToolNoArguments.generationSchema }
        let properties = tool.parameters.map { parameter in
            DynamicGenerationSchema.Property(name: parameter.name,
                                             description: parameter.description,
                                             schema: Self.valueSchema(for: parameter),
                                             isOptional: !parameter.isRequired)
        }
        let root = DynamicGenerationSchema(name: tool.name, description: tool.description,
                                           properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// One parameter's own schema: the vendor's type for the kind, with
    /// the band as a guide when — and only when — it is to be shown. An
    /// integer band is the whole numbers inside the declared band.
    private static func valueSchema(for parameter: ToolParameter) -> DynamicGenerationSchema {
        let shown = parameter.showsRange ? parameter.range : nil
        switch parameter.kind {
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self, guides: shown.map { [.range($0)] } ?? [])
        case .integer:
            let whole = shown.map { Int($0.lowerBound.rounded(.up))...Int($0.upperBound.rounded(.down)) }
            return DynamicGenerationSchema(type: Int.self, guides: whole.map { [.range($0)] } ?? [])
        }
    }

    /// The vendor calls this from inside the session while the reply is
    /// being generated; the answer goes back to the MODEL, not to us.
    ///
    /// THROUGH THE DOOR (F-13 g): the body is reachable no other way, so
    /// the adapter knocks on THIS answer's table (the route's, 5b) with
    /// the model's typed answer read by kind (AC-269) and THIS answer's
    /// confirmed names (F-10 B-ii). The door strips, checks, bands,
    /// flags, shields and caps; this function judges nothing.
    ///
    /// ANSWERED IN WORDS, NEVER THROWN (F-4 = B, AC-276): whatever the
    /// door decided — the answer, a refusal, a thrown body, a missing
    /// yes — goes back to the model as the door's sentence, the same one
    /// the MLX run feeds back, and the reply goes on to `.finished`. 4w
    /// let a throw through and the run ended `.failed`; that ending is
    /// gone.
    ///
    /// THE REENTRANCY LAW (§4.1), at the one `await` this file owns: a
    /// barge may have retired the run while the tool was busy. The run's
    /// `retired` latch is the PRIMARY guard — once `cancel()` has finished
    /// the output stream, nothing the framework produces afterwards
    /// reaches anyone (AC-226's rule). This check is the belt: the body
    /// ran to its end under the door's shield (F-5 A) and its write
    /// stands; its ANSWER dies here, before the vendor spends a prefill
    /// feeding it to a model nobody is listening to. The one throw left
    /// in this function is that `CancellationError`.
    func call(arguments: GeneratedContent) async throws -> String {
        let now = route.now
        let outcome = await now.table.invoke(tool.name, arguments: ToolArguments(arguments),
                                             confirmed: now.confirmed)
        try Task.checkCancellation()
        return outcome.wordsForModel
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleToolAdapter {
    /// The table, as the vendor's list — one adapter per `ReplyTool`, in
    /// the table's order, and `[]` for `.empty`. `[]` is the vendor's
    /// own default for `tools:`, so the session built from it is EXACTLY
    /// the one built before 4w (AC-227: a mind with no tools pays nothing
    /// for this file — measured, see `AppleSession.entries`).
    static func adapters(for table: ToolTable, confirmed: Set<String> = []) throws -> [any Tool] {
        let route = ToolRoute(table, confirmed: confirmed)
        return try table.tools.map { try AppleToolAdapter($0, route: route) }
    }
}

// MARK: - the model's typed answer, in the door's words (AC-269)

extension ToolValue {
    /// The vendor's `GeneratedContent`, read by KIND into the contract's
    /// value: one number case (F-13 b — the vendor has one too), strings,
    /// booleans, null, and the two structured shapes the door refuses for
    /// a scalar parameter (F-13 i) — kept as what they are so the refusal
    /// can say "a list" or "an object".
    @available(macOS 26.0, iOS 26.0, *)
    init(_ content: GeneratedContent) {
        switch content.kind {
        case .null: self = .null
        case .bool(let value): self = .boolean(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .array(let elements): self = .array(elements.map(ToolValue.init))
        case .structure(let properties, _): self = .object(properties.mapValues(ToolValue.init))
        @unknown default: self = .null
        }
    }
}

extension ToolArguments {
    /// The model's whole answer — a structure — as the door's arguments.
    /// Anything that is not a structure is no arguments at all (`.empty`):
    /// the door then reports every required parameter missing, in words.
    @available(macOS 26.0, iOS 26.0, *)
    init(_ content: GeneratedContent) {
        guard case .structure(let properties, _) = content.kind else { self = .empty; return }
        self = ToolArguments(properties.mapValues(ToolValue.init))
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
