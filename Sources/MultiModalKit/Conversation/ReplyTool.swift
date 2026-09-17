// THE TOOL A MIND MAY CALL — the contract's SHAPE (4z, SPEC §192–§197, D-110).
//
// THE SHAPE WITHOUT THE JUDGMENT (the ledger's precedent, 4c): every type
// the signed contract names is here with its final signature, so the
// door's tests compile and are SEEN red — and the door itself does what
// the spike's did: look the name up, run the body, fold a throw. No
// argument is stripped or checked, no flag is read, no answer is cut,
// no body is shielded. Each of those lands green in its own commit, in
// §195's order of the code.
//
// What did NOT change, on purpose: F-1 = B (the run executes the tool
// itself; the coordinator never sees a call), the exact-name lookup, and
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

/// What the model passed, read through typed accessors that THROW.
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
    /// The body. NOT public (F-13 g): the only way in is the checked door,
    /// `ToolTable.invoke`.
    let body: @Sendable (ToolArguments) async throws -> String

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

// MARK: - the tools a mind may call

/// The tools ONE generator holds by default, or ONE call carries
/// (`GenerationOptions.tools`, F-2 = A).
public struct ToolTable: Sendable, Equatable {
    public let tools: [ReplyTool]

    public init(_ tools: [ReplyTool] = []) {
        self.tools = tools
    }

    /// No tools at all — the shape every generator had before 4w.
    public static let empty = ToolTable()

    public var isEmpty: Bool { tools.isEmpty }

    /// The cap on a tool's answer, in characters (F-13 f).
    public static let answerCap = 4_000
    /// The sentence that marks a cut answer.
    public static let cutMarker = "\n[the rest of this answer was cut: it ran past the cap of 4000 characters]"

    /// THE lookup: exact name, first match, `nil` for a name no tool has.
    public subscript(name: String) -> ReplyTool? {
        tools.first { $0.name == name }
    }

    /// The SHAPE of equality (F-13 c lands with the door): names only.
    public static func == (lhs: ToolTable, rhs: ToolTable) -> Bool {
        lhs.tools.map(\.name) == rhs.tools.map(\.name)
    }

    /// THE DOOR — the one way to a tool's body (F-13 g). In this commit
    /// it is the spike's: look the name up, run the body, fold a throw.
    public func invoke(_ name: String,
                       arguments: ToolArguments,
                       confirmed: Set<String> = []) async -> ToolCallOutcome {
        guard let tool = self[name] else {
            return ToolCallOutcome(result: .failure(ToolCallFailure(tool: name, reason: .unknownTool)))
        }
        do {
            return ToolCallOutcome(result: .success(try await tool.body(arguments)))
        } catch {
            return ToolCallOutcome(result: .failure(
                ToolCallFailure(tool: name, reason: .threw(String(describing: error)))))
        }
    }
}
