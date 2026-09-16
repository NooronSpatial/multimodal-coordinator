// THE TOOL A MIND MAY CALL — the contract (4z, SPEC §192–§197, D-108).
//
// The spike (4w, D-101) held the SMALLEST thing both real minds could
// consume — a name, a description, and a function over `[String:
// String]` — and said in this file that the contract milestone would
// replace it. This is that replacement. What it adds is exactly what two
// callers needed and nothing they did not (§194): a tool DECLARES its
// parameters, so each mind can show the model a schema; a tool RECEIVES
// typed arguments, so no tool is a parser; and the table CHECKS the
// model's arguments against the declaration before the body runs, so a
// bad argument is a countable value and never a wrong number in an app.
//
// What did NOT change, on purpose: F-1 = B (the run executes the tool
// itself; the coordinator never sees a call), the exact-name lookup, and
// `String` as the answer both minds feed back verbatim (F-3 = A). A tool
// with no parameters is the spike's tool, unchanged (AC-277).

// MARK: - a value the model may pass

/// One argument as the model gave it — the JSON scalars, and nothing
/// nested (§194: arrays and objects are a later delta). A mind maps its
/// vendor's parsed value onto these; a tool reads them through
/// `ToolArguments`' accessors, never by pattern-matching here.
public enum ToolValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case null
}

extension ToolValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension ToolValue: CustomStringConvertible {
    /// How a value reads in a failure sentence: strings quoted, the rest
    /// as the model wrote them.
    public var description: String {
        switch self {
        case .string(let text): "\"\(text)\""
        case .number(let number): String(number)
        case .integer(let integer): String(integer)
        case .boolean(let flag): flag ? "true" : "false"
        case .null: "null"
        }
    }
}

// MARK: - a parameter the tool declares

/// One parameter of a tool, in the app's words (D-027): the name the
/// model uses, the sentence the model reads, the kind the value must
/// have, and whether the model may leave it out.
public struct ToolParameter: Sendable, Equatable {
    /// The four scalar kinds both callers' verbs need today (§194).
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case string, number, integer, boolean

        /// The word a failure sentence uses.
        var article: String {
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
    public let isRequired: Bool

    public init(name: String, description: String, kind: Kind, isRequired: Bool = true) {
        self.name = name
        self.description = description
        self.kind = kind
        self.isRequired = isRequired
    }
}

// MARK: - why an argument cannot be read (AC-271)

/// A typed, countable reason an argument was not what the tool needed.
/// Thrown by the accessors and folded by the table into
/// `ToolCallFailure.badArgument` before the body runs.
public struct ToolArgumentFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        /// Not given, or given as `null`.
        case missing
        /// Given, but not something the kind can be read from.
        case wrongKind(expected: ToolParameter.Kind, got: ToolValue)
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
            "argument '\(argument)' should be \(expected.article), got \(got)"
        }
    }
}

// MARK: - the arguments a tool receives (F-1 = A)

/// What the model passed, read through typed accessors that THROW. The
/// accessors are lenient about the shape a model writes a value in —
/// `"83.5"` reads as a number, `7.0` as a whole number, `"true"` as a
/// boolean — and strict about meaning: `7.5` is not a whole number and
/// `"yes"` is not true. `null` is absence.
public struct ToolArguments: Sendable, Equatable {
    public let values: [String: ToolValue]

    public init(_ values: [String: ToolValue] = [:]) {
        self.values = values
    }

    /// No arguments at all — the spike's read, and any tool without parameters.
    public static let none = ToolArguments()

    /// True when the model gave a value that is not `null`.
    public func has(_ name: String) -> Bool {
        if let value = values[name], value != .null { return true }
        return false
    }

    public func string(_ name: String) throws(ToolArgumentFailure) -> String {
        switch try present(name) {
        case .string(let text): return text
        case let other: throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .string, got: other))
        }
    }

    public func number(_ name: String) throws(ToolArgumentFailure) -> Double {
        let value = try present(name)
        switch value {
        case .number(let number): return number
        case .integer(let integer): return Double(integer)
        case .string(let text):
            if let number = Double(text.trimmingCharacters(in: .whitespaces)) { return number }
        default: break
        }
        throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .number, got: value))
    }

    public func integer(_ name: String) throws(ToolArgumentFailure) -> Int {
        let value = try present(name)
        switch value {
        case .integer(let integer): return integer
        case .number(let number):
            if number.rounded() == number, let integer = Int(exactly: number) { return integer }
        case .string(let text):
            if let integer = Int(text.trimmingCharacters(in: .whitespaces)) { return integer }
        default: break
        }
        throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .integer, got: value))
    }

    public func boolean(_ name: String) throws(ToolArgumentFailure) -> Bool {
        let value = try present(name)
        switch value {
        case .boolean(let flag): return flag
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
        default: break
        }
        throw ToolArgumentFailure(argument: name, reason: .wrongKind(expected: .boolean, got: value))
    }

    /// The one rule for absence: not there, or `null`.
    private func present(_ name: String) throws(ToolArgumentFailure) -> ToolValue {
        guard let value = values[name], value != .null else {
            throw ToolArgumentFailure(argument: name, reason: .missing)
        }
        return value
    }

    /// The declaration, checked (AC-271): every required parameter is
    /// present, and every given parameter can be read as its kind.
    /// Unknown extras are ignored — the model may add a word the tool
    /// never asked for, and that is not a reason to refuse the call.
    func check(against parameters: [ToolParameter]) -> ToolArgumentFailure? {
        for parameter in parameters {
            guard has(parameter.name) else {
                if parameter.isRequired { return ToolArgumentFailure(argument: parameter.name, reason: .missing) }
                continue
            }
            do {
                switch parameter.kind {
                case .string: _ = try string(parameter.name)
                case .number: _ = try number(parameter.name)
                case .integer: _ = try integer(parameter.name)
                case .boolean: _ = try boolean(parameter.name)
                }
            } catch {
                return error
            }
        }
        return nil
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
/// The name and the description are what the model reads; the parameters
/// are rendered by each mind into the schema the model is shown (Apple's
/// `GenerationSchema`, the MLX template's `<tools>` block); `call` runs
/// INSIDE the reply (F-1 = B), so it must be safe to call from any task
/// and must not touch the coordinator. It receives arguments the table
/// has already checked against the declaration.
public struct ReplyTool: Sendable {
    /// The name the model uses to ask for it. Exact-match, case-sensitive:
    /// one lookup rule for both minds (`ToolTable`).
    public let name: String
    /// What the model is told the tool does — the app's words (D-027).
    public let description: String
    /// What the model may pass, in the app's words. Empty is the spike's
    /// no-argument read, unchanged.
    public let parameters: [ToolParameter]
    /// The tool itself.
    public let call: @Sendable (ToolArguments) async throws -> String

    /// What the model is shown of this tool — everything but the body.
    public struct Declaration: Sendable, Equatable {
        public let name: String
        public let description: String
        public let parameters: [ToolParameter]
    }

    public var declaration: Declaration {
        Declaration(name: name, description: description, parameters: parameters)
    }

    public init(name: String,
                description: String,
                parameters: [ToolParameter] = [],
                call: @escaping @Sendable (ToolArguments) async throws -> String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.call = call
    }

    /// The whole of what a run must do with a model's request for THIS
    /// tool: check the arguments, run the body, fold a throw. Written
    /// once, used by the table (the MLX and scripted minds) and by the
    /// Apple adapter (whose framework does its own lookup).
    public func invoke(_ arguments: ToolArguments) async -> Result<String, ToolCallFailure> {
        if let failure = arguments.check(against: parameters) {
            return .failure(ToolCallFailure(tool: name, reason: .badArgument(failure)))
        }
        do {
            return .success(try await call(arguments))
        } catch {
            return .failure(ToolCallFailure(tool: name, reason: .threw(String(describing: error))))
        }
    }
}

// MARK: - why a call failed (AC-225, AC-271)

/// A tool call that did not produce an answer — typed, so a caller can
/// COUNT it, and `Equatable`, so a test can name the exact value.
///
/// Still a struct beside `ReplyFailure`, not a case in it: under F-4 = B
/// (both minds, since 4z) a failed call is answered to the MODEL in the
/// words below and the reply goes on, so the seam never reports it.
public struct ToolCallFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// What went wrong, in the three ways a call can.
    public enum Reason: Sendable, Equatable {
        /// The model asked for a name no tool has.
        case unknownTool
        /// The model's arguments do not fit the declaration (4z, AC-271).
        /// The body did not run.
        case badArgument(ToolArgumentFailure)
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

    /// The sentence a run hands BACK TO THE MODEL (F-4 = B), on either mind.
    public var description: String {
        switch reason {
        case .unknownTool:
            "no tool named '\(tool)'"
        case .badArgument(let failure):
            "tool '\(tool)' cannot run: \(failure.description)"
        case .threw(let words):
            "tool '\(tool)' failed: \(words)"
        }
    }
}

// MARK: - the tools a mind may call

/// The tools ONE generator holds by default — handed at construction —
/// or ONE call carries (`GenerationOptions.tools`, F-2 = A): tools are
/// policy the app grants, so they live with the mind the app configured
/// or ride on the call the app makes, never with the coordinator.
///
/// One lookup rule for every mind: exact name, first match, `nil` for a
/// name no tool has.
public struct ToolTable: Sendable, Equatable {
    public let tools: [ReplyTool]

    /// Two tables are equal when they show the model the same thing —
    /// the same names, words and parameters in the same order. The
    /// bodies are closures and cannot be compared; a test that needs to
    /// tell two bodies apart calls them. This is what lets
    /// `GenerationOptions` stay `Equatable` with a table on it.
    public static func == (lhs: ToolTable, rhs: ToolTable) -> Bool {
        lhs.tools.map(\.declaration) == rhs.tools.map(\.declaration)
    }

    /// THE resolution rule, written once for every mind (F-2 = A): the
    /// call's table when the call carries one — even an empty one — and
    /// this table otherwise.
    public func resolved(for options: GenerationOptions) -> ToolTable {
        options.tools ?? self
    }

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

    /// Looks the name up, checks the arguments, runs the tool, and folds
    /// every way a call can fail into one typed value — so the MLX mind
    /// and the scripted mind do it the same way. (The Apple mind's
    /// framework does its own lookup and reaches `ReplyTool.invoke`
    /// through its `Tool` adapter.)
    public func call(_ name: String,
                     arguments: ToolArguments) async -> Result<String, ToolCallFailure> {
        guard let tool = self[name] else {
            return .failure(ToolCallFailure(tool: name, reason: .unknownTool))
        }
        return await tool.invoke(arguments)
    }
}
