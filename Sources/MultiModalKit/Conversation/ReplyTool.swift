// THE TOOL A MIND MAY CALL — the contract (4z, SPEC §192–§197, D-110).
//
// The spike (4w, D-101) held the SMALLEST thing both real minds could
// consume — a name, a description, and a function over `[String:
// String]` — and said in this file that the contract milestone would
// replace it. This is that replacement. What it adds is exactly what two
// callers needed and nothing they did not (§194): a tool DECLARES its
// parameters, so each mind can show the model a schema; a tool RECEIVES
// typed arguments, so no tool is a parser; the table's DOOR checks the
// model's arguments against the declaration before the body runs, so a
// bad argument is a countable value and never a wrong number in an app;
// and one policy bit — the person's yes for a flagged tool — is enforced
// at that door, not left to the model.
//
// What did NOT change, on purpose: F-1 = B (the run executes the tool
// itself; the coordinator never runs one — since 5b it hears of each use
// after the fact, D-120), the exact-name lookup, and
// `String` as the answer both minds feed back verbatim (F-3 = A). A tool
// with no parameters is the spike's tool, unchanged (AC-283).

// MARK: - a value the model may pass (F-1 = A)

/// One argument as the model gave it. ONE number case (F-13 b): the
/// Apple vendor has one number kind, so `84` parsed on the MLX side and
/// `84.0` read on the Apple side are the same value. A nested value
/// (`.array`, `.object`) is carried so the door can refuse it for a
/// scalar parameter (F-13 i, §194's four scalars).
public enum ToolValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case array([ToolValue])
    case object([String: ToolValue])
}

extension ToolValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension ToolValue: CustomStringConvertible {
    /// How a value reads in a sentence to the model: text quoted, a whole
    /// number without its ".0", the rest as the model wrote them.
    public var description: String {
        switch self {
        case .string(let text): "\"\(text)\""
        case .number(let number): Self.plain(number)
        case .boolean(let flag): flag ? "true" : "false"
        case .null: "null"
        case .array: "a list"
        case .object: "an object"
        }
    }

    /// `84` for a whole number, `83.5` otherwise — the way a person
    /// would write it, so the model reads `between 20 and 300`.
    static func plain(_ number: Double) -> String {
        if let whole = Int(exactly: number) { return String(whole) }
        return String(number)
    }
}

// MARK: - a parameter the tool declares

/// One parameter of a tool, in the app's words (D-027): the name the
/// model uses, the sentence the model reads, the kind the value must
/// have, whether the model may leave it out — and, for a number, an
/// optional band with its own "shown" switch (F-11 B).
public struct ToolParameter: Sendable, Equatable {
    /// The four scalar kinds both callers' verbs need today (§194).
    /// `.integer` is a KIND the schema names; the VALUE is still
    /// `.number` (F-13 b), and a non-whole value for it is refused.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case string, number, integer, boolean

        /// The words a sentence to the model uses for the kind.
        var words: String {
            switch self {
            case .string: "a string"
            case .number: "a number"
            case .integer: "a whole number"
            case .boolean: "true or false"
            }
        }
    }

    public let name: String
    public let description: String
    public let kind: Kind
    /// NO default (F-13 k): a required parameter is a demand the model
    /// meets from nothing (F-11's first caution), so the app writes it.
    public let isRequired: Bool
    /// The closed band a `.number` or `.integer` value must fall in, or
    /// nil for no band (F-11 B). Checked by the door; SHOWN to the model
    /// only when `showsRange` says so — two switches, measured apart.
    public let range: ClosedRange<Double>?
    /// Whether the band is rendered into the schema the model reads.
    /// False whenever there is no band.
    public let showsRange: Bool

    public init(name: String, description: String, kind: Kind, isRequired: Bool) {
        self.name = name
        self.description = description
        self.kind = kind
        self.isRequired = isRequired
        self.range = nil
        self.showsRange = false
    }

    public init(name: String, description: String, kind: Kind, isRequired: Bool,
                range: ClosedRange<Double>, showsRange: Bool) {
        self.name = name
        self.description = description
        self.kind = kind
        self.isRequired = isRequired
        self.range = range
        self.showsRange = showsRange
    }
}

// MARK: - why an argument cannot be read

/// A typed, countable reason one argument was not what the tool needed.
public struct ToolArgumentFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        /// Not given, or given as `null` (F-13 j).
        case missing
        /// Given, but not something the kind can be read from.
        case wrongKind(expected: ToolParameter.Kind, got: ToolValue)
        /// A number outside the declared band (F-11 B).
        case outOfRange(allowed: ClosedRange<Double>, got: Double)
    }

    public let argument: String
    public let reason: Reason

    public init(argument: String, reason: Reason) {
        self.argument = argument
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case .missing:
            "argument '\(argument)' is missing"
        case .wrongKind(let expected, let got):
            "argument '\(argument)' should be \(expected.words), got \(got)"
        case .outOfRange(let allowed, let got):
            "argument '\(argument)' should be between \(ToolValue.plain(allowed.lowerBound)) "
                + "and \(ToolValue.plain(allowed.upperBound)), got \(ToolValue.plain(got))"
        }
    }
}

// MARK: - the arguments a tool receives (F-1 = A)

/// What the model passed, read through typed accessors that THROW —
/// so no tool is a parser, and a wrong value is a typed, countable
/// failure rather than a silent `nil` (F-1 = A).
///
/// The accessors are STRICT, because the door was lenient for them
/// (F-8 C): what a body receives has already been stripped to the
/// declared names, checked against the declared kinds and bands, and
/// normalised — a model's `"84"` for a number parameter arrives here as
/// `.number(84)`. So a throw from an accessor inside a body means the
/// body asked for a kind it did not declare, and the door folds it into
/// `.threw` like any other error of the tool's own.
public struct ToolArguments: Sendable, Equatable {
    public let values: [String: ToolValue]

    public init(_ values: [String: ToolValue] = [:]) {
        self.values = values
    }

    /// No arguments at all — the spike's read, and any tool without
    /// parameters. Named `empty` beside `ToolTable.empty` (F-13 a): a
    /// static called `none` shadows `Optional.none`.
    public static let empty = ToolArguments()

    /// True when the model gave a value that is not `null`.
    public func has(_ name: String) -> Bool {
        if let value = values[name], value != .null { return true }
        return false
    }

    public func string(_ name: String) throws -> String {
        let value = try present(name)
        guard case .string(let text) = value else {
            throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .string, got: value))
        }
        return text
    }

    public func number(_ name: String) throws -> Double {
        let value = try present(name)
        guard case .number(let number) = value else {
            throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .number, got: value))
        }
        return number
    }

    public func integer(_ name: String) throws -> Int {
        let value = try present(name)
        guard case .number(let number) = value, let whole = Int(exactly: number) else {
            throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .integer, got: value))
        }
        return whole
    }

    public func boolean(_ name: String) throws -> Bool {
        let value = try present(name)
        guard case .boolean(let flag) = value else {
            throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .boolean, got: value))
        }
        return flag
    }

    /// The one rule for absence: not there, or `null`.
    private func present(_ name: String) throws -> ToolValue {
        guard let value = values[name], value != .null else {
            throw ToolArgumentFailure(argument: name, reason: .missing)
        }
        return value
    }
}

extension ToolArguments: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ToolValue)...) {
        self.init(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - one tool

/// One thing a reply may ask for while it is being generated.
///
/// The name and the description are what the model reads; the
/// parameters are what each mind renders into the schema the model is
/// shown (the Apple `GenerationSchema`, the MLX template's `<tools>`
/// block) and what the door checks a call against; the flag is the
/// app's one policy bit. The body runs INSIDE the reply (F-1 = B), so
/// it must be safe to call from any task and must not touch the
/// coordinator; it is reached only through `ToolTable.invoke`, which
/// hands it arguments already checked against this declaration.
public struct ReplyTool: Sendable {
    /// The name the model uses to ask for it. Exact-match, case-sensitive:
    /// one lookup rule for both minds (`ToolTable`).
    public let name: String
    /// What the model is told the tool does — the app's words (D-027).
    public let description: String
    /// What the model may pass, in the app's words. Empty is the spike's
    /// no-argument read, unchanged (AC-283).
    public let parameters: [ToolParameter]
    /// The app's one policy bit (F-10 B): a flagged tool does not run on
    /// the model's word alone. NO default (as F-13 k): the app writes it.
    public let requiresConfirmation: Bool
    /// The body. PRIVATE (F-13 g): the only way in is the checked door,
    /// `ToolTable.invoke`, in this file — inside the module too, so the
    /// compiler checks the sentence.
    private let body: @Sendable (ToolArguments) async throws -> String

    public init(name: String,
                description: String,
                parameters: [ToolParameter],
                requiresConfirmation: Bool,
                body: @escaping @Sendable (ToolArguments) async throws -> String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
        self.body = body
    }
}

// MARK: - why a call failed (AC-225, AC-273)

/// A tool call that did not produce an answer — typed, so a caller can
/// COUNT it, and `Equatable`, so a test can name the exact value.
public struct ToolCallFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        /// The model asked for a name no tool has (F-4 = B's case).
        case unknownTool
        /// The model's arguments do not fit the declaration; the body
        /// did not run (AC-273, AC-280).
        case badArgument(ToolArgumentFailure)
        /// The tool is flagged and the person has not said yes; the body
        /// did not run (F-10 B, AC-279).
        case needsConfirmation
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

    /// The sentence a run hands BACK TO THE MODEL (F-4 = B).
    public var description: String {
        switch reason {
        case .unknownTool:
            "no tool named '\(tool)'"
        case .badArgument(let failure):
            "tool '\(tool)' cannot run: \(failure.description)"
        case .needsConfirmation:
            "tool '\(tool)' needs the person's confirmation: ask them, and call it again once they have said yes"
        case .threw(let words):
            "tool '\(tool)' failed: \(words)"
        }
    }
}

// MARK: - what the door did with one request

/// The answer or the refusal, and the counts the door kept on the way.
public struct ToolCallOutcome: Sendable, Equatable {
    public let result: Result<String, ToolCallFailure>
    /// The argument names the model added that the tool never declared,
    /// removed before the body (F-7 C). Sorted, so a count is a fact.
    public let stripped: [String]
    /// The declared names whose value was written in the wrong shape and
    /// read leniently — `"84"` for a number (F-8 C). In declaration order.
    public let coerced: [String]
    /// True when the answer ran past the cap and was cut (F-13 f).
    public let cut: Bool

    public init(result: Result<String, ToolCallFailure>,
                stripped: [String] = [], coerced: [String] = [], cut: Bool = false) {
        self.result = result
        self.stripped = stripped
        self.coerced = coerced
        self.cut = cut
    }

    /// The words that go back to the model, either way (F-4 = B).
    public var wordsForModel: String {
        switch result {
        case .success(let answer): answer
        case .failure(let failure): failure.description
        }
    }
}

// MARK: - a declaration no mind can show (AC-289, F-13 d)

/// A table declared in a way no mind can render into the schema the
/// model reads — the APP's error, typed so the app reads WHICH tool and
/// WHICH parameter, and thrown where the table is handed over (F-13 d):
/// a generator's init for its default table, `openReply` for a per-call
/// one. Never from inside a reply: the rendering runs in the reply's own
/// task, where nothing can throw and a trap takes the process.
///
/// Mind-agnostic on purpose. The rule is the DECLARATION's, not a
/// template's, so both real minds refuse the same table with the same
/// words — checked once, in `ToolTable.checkDeclarations`.
public enum ToolDeclarationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Two parameters of one tool share a name. A JSON-schema object
    /// holds ONE property per name — the MLX template's `properties`, the
    /// Apple vendor's `duplicateProperty` — so no schema can carry both,
    /// and the door, which reads the names as a set, would check one
    /// value against two declarations.
    case duplicateParameter(tool: String, parameter: String)

    public var description: String {
        switch self {
        case .duplicateParameter(let tool, let parameter):
            "tool '\(tool)' declares the parameter '\(parameter)' more than once"
        }
    }
}

// MARK: - the tools a mind may call

/// The tools ONE generator holds by default — handed at construction —
/// or ONE call carries (`GenerationOptions.tools`, F-2 = A): tools are
/// policy the app grants, so they live with the mind the app configured
/// or ride on the call the app makes, never with the coordinator.
///
/// It exists so every mind shares ONE lookup rule and ONE door instead
/// of each writing its own. The rule: exact name, first match, `nil` for
/// a name no tool has. The door: `invoke`, below — the whole of what a
/// run must do with a model's request, written once.
public struct ToolTable: Sendable, Equatable {
    public let tools: [ReplyTool]

    public init(_ tools: [ReplyTool] = []) {
        self.tools = tools
    }

    /// No tools at all — the shape every generator had before 4w, and
    /// "none this turn" on a call's options (F-2 = A).
    public static let empty = ToolTable()

    public var isEmpty: Bool { tools.isEmpty }

    /// The cap on what goes back to the model, in characters (F-13 f):
    /// 4,000 ≈ 3 s of prefill on the 4B at §69's 0.74 ms per character.
    /// A tool that answers with a whole session as JSON is bounded here;
    /// an app that wants a short answer returns a short answer.
    public static let answerCap = 4_000
    /// The sentence that marks a cut, after the cap's worth of text. The
    /// number is READ from `answerCap`, so the marker cannot lie to the
    /// model when the cap moves.
    public static let cutMarker =
        "\n[the rest of this answer was cut: it ran past the cap of \(answerCap) characters]"

    /// THE lookup: exact name, first match, `nil` for a name no tool has.
    public subscript(name: String) -> ReplyTool? {
        tools.first { $0.name == name }
    }

    /// Equal when they show the model the same thing (F-13 c): the same
    /// names, words, parameters and flags, in the same order. The bodies
    /// are closures and cannot be compared, so two tables that DO
    /// different things compare equal — pinned by a row (AC-290) so
    /// nobody is surprised. This is what keeps `GenerationOptions`
    /// `Equatable` with a table on it.
    public static func == (lhs: ToolTable, rhs: ToolTable) -> Bool {
        lhs.tools.map(\.declaration) == rhs.tools.map(\.declaration)
    }

    // MARK: the check on the declarations (AC-289, F-13 d)

    /// What no mind can show the model, refused where the table is
    /// handed over and never inside a reply. Both real minds call it —
    /// the generator's init for its default table, `openReply` for a
    /// per-call one — so the rendering a reply does later never meets a
    /// declaration it cannot render. Public so an app can check its own
    /// table before it builds a mind, the shape `Config.validate()` has.
    ///
    /// ONE rule today: no two parameters of one tool share a name. Two
    /// TOOLS sharing a name is not an error — the lookup rule above
    /// ("exact name, first match") already says what that means. The
    /// FIRST offence is the one named — table order, then declaration
    /// order — so the sentence is deterministic and an app with two
    /// mistakes reads them one at a time. Exact names, as the lookup
    /// reads them: `kg` and `KG` are two parameters.
    ///
    /// Nothing about `invoke` changes: the door reads a table exactly as
    /// it did, and a table this refuses is one the door was never handed.
    public func checkDeclarations() throws(ToolDeclarationError) {
        for tool in tools {
            var seen: Set<String> = []
            for parameter in tool.parameters where !seen.insert(parameter.name).inserted {
                throw .duplicateParameter(tool: tool.name, parameter: parameter.name)
            }
        }
    }

    // MARK: the door

    /// THE DOOR — the only way to a tool's body (F-13 g), and the one
    /// place every check lives, so the MLX mind, the scripted mind and
    /// the Apple adapter cannot drift apart. The stops, in §195's order:
    ///
    ///     name ─► unknown? ─► extras stripped, counted (F-7 C)
    ///       ─► each declared parameter: absent or null and required →
    ///          .missing (F-13 j); the wrong kind → .wrongKind, with text
    ///          read leniently into a number or a boolean and COUNTED
    ///          (F-8 C; "nan"/"inf" refused; a nested value refused,
    ///          F-13 i; a non-whole value refused for an integer, F-13 b);
    ///          outside the declared band → .outOfRange (F-11 B)
    ///       ─► flagged and the name not in `confirmed` → .needsConfirmation
    ///          (F-10 B-ii: the yes is the app's, on the call's options)
    ///       ─► the BODY, with only the declared names and the values the
    ///          door normalised (a coerced "84" arrives as 84)
    ///       ─► the answer, or a thrown tool's own words (F-13 e), cut at
    ///          the cap and counted (F-13 f) ─► the words for the model
    ///
    /// Why the arguments are checked BEFORE the flag is read: a bad call
    /// is a bad call whatever the policy, and the model should learn the
    /// argument it got wrong rather than ask the person for a yes to a
    /// call that could never run. Why every refusal is a typed value and
    /// a sentence: F-4 = B — the model is told in words and recovers;
    /// the app counts. Nothing here is a `ReplyFailure`: a refused tool
    /// is not a failed reply.
    public func invoke(_ name: String,
                       arguments: ToolArguments,
                       confirmed: Set<String> = []) async -> ToolCallOutcome {
        guard let tool = self[name] else {
            return ToolCallOutcome(result: .failure(ToolCallFailure(tool: name, reason: .unknownTool)))
        }
        let declared = Set(tool.parameters.map(\.name))
        let stripped = arguments.values.keys.filter { !declared.contains($0) }.sorted()

        var admitted: [String: ToolValue] = [:]
        var coerced: [String] = []
        for parameter in tool.parameters {
            guard let value = arguments.values[parameter.name], value != .null else {
                if parameter.isRequired {
                    return refusal(tool, stripped: stripped, coerced: coerced,
                                   ToolArgumentFailure(argument: parameter.name, reason: .missing))
                }
                continue
            }
            switch parameter.read(value) {
            case .exact(let read):
                admitted[parameter.name] = read
            case .coerced(let read):
                admitted[parameter.name] = read
                coerced.append(parameter.name)
            case .refused(let reason):
                return refusal(tool, stripped: stripped, coerced: coerced,
                               ToolArgumentFailure(argument: parameter.name, reason: reason))
            }
        }

        if tool.requiresConfirmation, !confirmed.contains(name) {
            return ToolCallOutcome(result: .failure(ToolCallFailure(tool: name, reason: .needsConfirmation)),
                                   stripped: stripped, coerced: coerced)
        }

        let (result, cut) = await tool.run(ToolArguments(admitted))
        return ToolCallOutcome(result: result, stripped: stripped, coerced: coerced, cut: cut)
    }

    private func refusal(_ tool: ReplyTool, stripped: [String], coerced: [String],
                         _ failure: ToolArgumentFailure) -> ToolCallOutcome {
        ToolCallOutcome(result: .failure(ToolCallFailure(tool: tool.name, reason: .badArgument(failure))),
                        stripped: stripped, coerced: coerced)
    }
}

extension ReplyTool {
    /// What the model is shown of this tool, and what equality reads:
    /// everything but the body (F-13 c). The flag is part of it (F-10 B),
    /// so a flagged and an unflagged declaration of one verb are two.
    struct Declaration: Equatable {
        let name: String
        let description: String
        let parameters: [ToolParameter]
        let requiresConfirmation: Bool
    }

    var declaration: Declaration {
        Declaration(name: name, description: description,
                    parameters: parameters, requiresConfirmation: requiresConfirmation)
    }

    /// The body, then the cap. The answer and a thrown tool's own words
    /// are cut alike (F-13 e under F-13 f): both go back to the model,
    /// and the cap is on what the model reads. `cut` is the count.
    ///
    /// THE BODY RUNS TO ITS END (F-5 = A, AC-277; Ryad's own letter in
    /// D-110). A barge cancels the reply's task tree — the run, the
    /// round, the await on this call — and before this line that
    /// cancellation reached INTO the tool's body: a tool that looked at
    /// `Task.isCancelled` before committing (the kind an app writes)
    /// skipped its write, and the diet app's `log_weight` would have
    /// been half-done by a person clearing their throat. So the body
    /// runs in a task of its own that the reply's cancellation does not
    /// reach: an unstructured `Task` does not inherit its creator's
    /// cancellation, and `.value` waits for it whether or not the waiter
    /// was cancelled.
    ///
    /// THE ISLAND, AND ITS PROOF (§4.1: small, documented, provably safe).
    /// It is awaited on the next line, never leaked, never `detached` —
    /// its lifetime is exactly this call's. Its result is a value. It
    /// holds only the `@Sendable` body and the `Sendable` arguments, no
    /// actor, no lock. Correctness never rested on cancellation:
    /// cancellation is a request (§4.1), and whether anyone is still
    /// listening is the RUN's question — the ticket it re-checks after
    /// this returns (`retired` on the MLX run, `cancelled` on the scripted
    /// one, the Apple adapter's `checkCancellation`) — so a dead reply's
    /// result goes nowhere while the app's state stands. It is NOT the
    /// only unstructured task in the library — grep `Task {` in
    /// `Sources/` for the others (the reply runs, the token streams, the
    /// ears, the mouths, the prewarms, 4y's deadline sleeper), each with
    /// its own reason on its page; no number is written here, because a
    /// number is exactly the sentence one grep refutes.
    ///
    /// THE PRICE, stated and accepted in D-110: no tool at all — a slow
    /// READ included — can be stopped by a barge; a network read runs to
    /// its end on a reply nobody is listening to. (C, per-tool opt-in,
    /// was the recommendation Ryad overruled; B, a rule the library
    /// cannot prove, and D, the shield written once per mind, were
    /// rejected with it.)
    fileprivate func run(_ arguments: ToolArguments) async -> (Result<String, ToolCallFailure>, cut: Bool) {
        let body = body
        let shielded = Task { try await body(arguments) }
        do {
            let (answer, cut) = Self.capped(try await shielded.value)
            return (.success(answer), cut)
        } catch {
            let (words, cut) = Self.capped(String(describing: error))
            return (.failure(ToolCallFailure(tool: name, reason: .threw(words))), cut)
        }
    }

    /// `text` unchanged under the cap; cut at the cap with the marker
    /// after it, and `true`, past it. Counted in `Character`s, the unit
    /// a person would count in.
    static func capped(_ text: String) -> (String, cut: Bool) {
        guard text.count > ToolTable.answerCap else { return (text, false) }
        return (String(text.prefix(ToolTable.answerCap)) + ToolTable.cutMarker, true)
    }
}

extension ToolParameter {
    /// What the door decided about one given value, against this
    /// parameter's kind and band.
    enum Reading {
        /// The value already had the kind; handed on as it was.
        case exact(ToolValue)
        /// Text that read as the kind (F-8 C): handed on as the kind's
        /// value, and counted.
        case coerced(ToolValue)
        case refused(ToolArgumentFailure.Reason)
    }

    /// The kind check and the band check, in that order (§195's path).
    ///
    /// The leniency is ONE WAY, as the reference branch had it and F-8 C
    /// kept: text may read as a number or a boolean, because chat models
    /// write `"84"` and `"true"`; nothing reads as text, so a number for
    /// a `.string` parameter is refused (a body that wanted a number
    /// declares one). Exactly the ruling's words and no more: `"true"`
    /// and `"false"` as JSON spells them, a number as `Double` parses
    /// it — no trimming, no case-folding. Finite numbers only:
    /// `Double("nan")` and `Double("inf")` parse, and both are refused.
    func read(_ value: ToolValue) -> Reading {
        switch kind {
        case .string:
            if case .string = value { return .exact(value) }
            return .refused(.wrongKind(expected: .string, got: value))
        case .boolean:
            switch value {
            case .boolean: return .exact(value)
            case .string("true"): return .coerced(.boolean(true))
            case .string("false"): return .coerced(.boolean(false))
            default: return .refused(.wrongKind(expected: .boolean, got: value))
            }
        case .number, .integer:
            return readNumber(value)
        }
    }

    private func readNumber(_ value: ToolValue) -> Reading {
        guard let read = Self.finiteNumber(in: value) else {
            return .refused(.wrongKind(expected: kind, got: value))
        }
        if kind == .integer, Int(exactly: read.number) == nil {
            return .refused(.wrongKind(expected: .integer, got: value))
        }
        if let range, !range.contains(read.number) {
            return .refused(.outOfRange(allowed: range, got: read.number))
        }
        return read.wasText ? .coerced(.number(read.number)) : .exact(value)
    }

    /// The finite number a value holds — as given, or parsed from text
    /// (`wasText`, the coercion to count) — or nil.
    private static func finiteNumber(in value: ToolValue) -> (number: Double, wasText: Bool)? {
        switch value {
        case .number(let given):
            return given.isFinite ? (given, false) : nil
        case .string(let text):
            guard let parsed = Double(text), parsed.isFinite else { return nil }
            return (parsed, true)
        default:
            return nil
        }
    }
}
