import Foundation
import FoundationModels
import Testing
@testable import MultiModalKit
import MultiModalKitTesting

/// The second half of `AppleToolTests` (one file was over the house's
/// type-length rule): the SCHEMA the model is shown, the TABLE resolved
/// per call, and a table no mind can show — AC-270, AC-275, AC-289.
extension AppleToolTests {

    // MARK: the schema the model is shown (AC-270)

    @Test("the schema names the parameters — four kinds, one optional, the app's sentences (AC-270)")
    func schemaNamesTheParameters() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let shown = try Self.json(of: try AppleToolAdapter(Self.fourKinds).parameters)
        let properties = try #require(shown["properties"] as? [String: Any], "schema: \(shown)")
        #expect(Set(properties.keys) == ["kg", "note", "reps", "fasted"],
                "exactly the parameters' names: \(properties.keys.sorted())")
        func property(_ name: String) throws -> [String: Any] {
            try #require(properties[name] as? [String: Any], "\(name): \(properties)")
        }
        #expect(try property("kg")["type"] as? String == "number")
        #expect(try property("note")["type"] as? String == "string")
        #expect(try property("reps")["type"] as? String == "integer")
        #expect(try property("fasted")["type"] as? String == "boolean")
        #expect(try property("kg")["description"] as? String == "the weight in kilograms",
                "the app's sentence, verbatim")
        let required = Set(shown["required"] as? [String] ?? [])
        #expect(required == ["kg", "reps", "fasted"], "the optional one is not required: \(required)")
    }

    @Test("a band is shown only when the declaration says so — two switches (F-11 B)")
    func bandIsShownOnlyWhenAsked() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        func kg(showsRange: Bool) -> ReplyTool {
            ReplyTool(name: "log_reading", description: "records a reading",
                      parameters: [ToolParameter(name: "kg", description: "the weight", kind: .number,
                                                 isRequired: true, range: 20...400, showsRange: showsRange)],
                      requiresConfirmation: false) { _ in "" }
        }
        let shownSchema = try Self.json(of: try AppleToolAdapter(kg(showsRange: true)).parameters)
        let shown = try #require((shownSchema["properties"] as? [String: Any])?["kg"] as? [String: Any])
        #expect(shown["minimum"] as? Double == 20 && shown["maximum"] as? Double == 400,
                "shown: the band rides into the schema: \(shown)")
        let hiddenSchema = try Self.json(of: try AppleToolAdapter(kg(showsRange: false)).parameters)
        let hidden = try #require((hiddenSchema["properties"] as? [String: Any])?["kg"] as? [String: Any])
        #expect(hidden["minimum"] == nil && hidden["maximum"] == nil,
                "not shown: the model reads no band, the door still checks it: \(hidden)")
    }

    @Test("two parameters with one name: the vendor's own schema builder refuses too (AC-289's second line)")
    func vendorRefusesADuplicateName() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let twice = ReplyTool(name: "log_reading", description: "records",
                              parameters: [
                                ToolParameter(name: "kg", description: "first", kind: .number, isRequired: true),
                                ToolParameter(name: "kg", description: "again", kind: .number, isRequired: true)
                              ],
                              requiresConfirmation: false) { _ in "" }
        #expect(throws: GenerationSchema.SchemaError.self) {
            _ = try AppleToolAdapter.schema(for: twice)
        }
    }

    // MARK: the model's typed answer, read by kind (AC-269)

    @Test("GeneratedContent is read by kind into ToolValue — one number case; list and object kept (AC-269)")
    func generatedContentReadsByKind() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(ToolValue(try GeneratedContent(json: "83.5")) == .number(83.5))
        #expect(ToolValue(try GeneratedContent(json: "84")) == .number(84), "a whole number is the one number case")
        #expect(ToolValue(try GeneratedContent(json: "\"morning\"")) == .string("morning"))
        #expect(ToolValue(try GeneratedContent(json: "true")) == .boolean(true))
        #expect(ToolValue(try GeneratedContent(json: "null")) == .null)
        #expect(ToolValue(try GeneratedContent(json: "[1, \"a\"]")) == .array([.number(1), .string("a")]))
        #expect(ToolValue(try GeneratedContent(json: "{\"a\": 1}")) == .object(["a": .number(1)]))
    }

    @Test("the model's whole answer becomes the door's arguments; not a structure is no arguments (AC-269)")
    func wholeAnswerBecomesArguments() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let arguments = ToolArguments(try GeneratedContent(json: "{\"kg\": 83.5, \"note\": \"morning\"}"))
        #expect(arguments == ToolArguments(["kg": 83.5, "note": "morning"]))
        #expect(ToolArguments(try GeneratedContent(json: "[1, 2]")) == .empty, "a list is not an argument set")
        #expect(ToolArguments(try GeneratedContent(json: "\"kg\"")) == .empty)
    }

    // MARK: the table per call (F-2 = A, AC-275 on this mind)

    @Test("an empty table hands the vendor no tools (AC-227's plain path)")
    func emptyTableHandsOverNothing() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(try AppleToolAdapter.adapters(for: .empty).isEmpty)
        let generator = try AppleReplyGenerator()
        #expect(generator.tools.isEmpty)
        let source = generator.source as? SessionKeeper
        #expect(source?.tools.isEmpty == true, "the real source was built with no tools")
    }

    @Test("a table becomes one adapter per tool, in the table's order, and rides to the real source")
    func tableBecomesAdaptersInOrder() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let table = ToolTable([
            ReplyTool(name: "session", description: "reads today's session",
                      parameters: [], requiresConfirmation: false) { _ in "" },
            ReplyTool(name: "weather", description: "reads the sky",
                      parameters: [], requiresConfirmation: false) { _ in "" }
        ])
        let adapters = try AppleToolAdapter.adapters(for: table)
        #expect(adapters.map(\.name) == ["session", "weather"])
        #expect(adapters.map(\.description) == ["reads today's session", "reads the sky"])
        let generator = try AppleReplyGenerator(instructions: "speak briefly", tools: table)
        #expect(generator.tools.tools.map(\.name) == ["session", "weather"])
        let source = generator.source as? SessionKeeper
        #expect(source?.tools.tools.map(\.name) == ["session", "weather"])
    }

    @Test("the session's table is resolved per call: the call's over the default, .empty means none this turn (AC-275)")
    func tableIsResolvedPerCall() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let session = ReplyTool(name: "session", description: "reads", parameters: [],
                                requiresConfirmation: false) { _ in "" }
        let timer = ReplyTool(name: "set_timer", description: "sets", parameters: [],
                              requiresConfirmation: false) { _ in "" }
        let source = SessionKeeper(maker: AppleSessionMaker(), tools: ToolTable([session]))
        #expect(source.resolvedTools(for: GenerationOptions()).tools.map(\.name) == ["session"],
                "nil: the default table")
        let replaced = source.resolvedTools(for: GenerationOptions(tools: ToolTable([timer])))
        #expect(replaced.tools.map(\.name) == ["set_timer"], "a table on the call replaces the default for that call")
        #expect(source.resolvedTools(for: GenerationOptions(tools: .empty)).isEmpty,
                ".empty on the call: no tool this turn")
        let none = SessionKeeper(maker: AppleSessionMaker(), tools: .empty)
        let given = none.resolvedTools(for: GenerationOptions(tools: ToolTable([timer])))
        #expect(given.tools.map(\.name) == ["set_timer"], "a generator with no table calls the call's tool")
    }

    // MARK: a table no mind can show (F-13 d, AC-289)

    static let duplicated = ToolTable([ReplyTool(
        name: "log_reading", description: "records",
        parameters: [
            ToolParameter(name: "kg", description: "first", kind: .number, isRequired: true),
            ToolParameter(name: "kg", description: "again", kind: .number, isRequired: true)
        ],
        requiresConfirmation: false) { _ in "" }])

    @Test("a bad DEFAULT table throws from the generator's init, typed (AC-289)")
    func badDefaultTableThrowsFromInit() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(throws: ToolDeclarationError.duplicateParameter(tool: "log_reading", parameter: "kg")) {
            _ = try AppleReplyGenerator(tools: Self.duplicated)
        }
    }

    @Test("a bad PER-CALL table throws from openReply, before the stream — the source is never asked (AC-289)")
    func badPerCallTableThrowsFromOpenReply() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let generator = try AppleReplyGenerator(source: source)
        let words = ToolDeclarationError.duplicateParameter(tool: "log_reading", parameter: "kg").description
        await #expect(throws: ReplyFailure.engine(words)) {
            _ = try await generator.openReply(to: ReplyContext(
                transcript: "hello", options: GenerationOptions(tools: Self.duplicated)))
        }
        #expect(source.recorded.isEmpty, "no stream was opened for a table no mind can show")
    }

}
