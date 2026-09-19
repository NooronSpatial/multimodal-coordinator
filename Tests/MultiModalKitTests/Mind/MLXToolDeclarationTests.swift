import Foundation
import MultiModalKitTesting
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// A TABLE NO MIND CAN SHOW, REFUSED AT THE MLX MIND'S TWO DOORS (4z piece
// 2b, AC-289; D-110 F-13 d applied to this mind).
//
// The trap this replaces: `MLXTools.toolSpec` built the schema's
// `properties` with `Dictionary(uniqueKeysWithValues:)`, so two
// parameters of one name crashed the process INSIDE the generation task,
// after `openReply` had returned — where nothing can throw. The ruling
// puts the throw where the table is handed over: the generator's init
// for its DEFAULT table, `openReply` for a PER-CALL one, to the caller,
// on the same call, before any run exists. The rule itself is the core's
// (`ToolTable.checkDeclarations`, `ToolContractTests+Declarations`);
// these rows prove the two doors call it and what a caller sees.
//
// No row renders a duplicate: that state is what the doors forbid, and a
// red version of such a row would be a crash, not a failure. The
// rendering's pin is `ToolSpecTests` — a table the check passed renders
// the 4w bytes exactly.

@Suite("4z · a table no mind can show is refused at the MLX door, never rendered (AC-289)",
       .timeLimit(.minutes(1)))
struct MLXToolDeclarationTests {
    private static let value = ToolParameter(name: "value", description: "the reading",
                                             kind: .number, isRequired: true)
    /// The one mistake the check refuses: `value` declared twice.
    private static let twiceValue = ToolTable([ReplyTool(
        name: "log_reading", description: "Record one reading.",
        parameters: [value, value], requiresConfirmation: false) { _ in "logged" }])
    private static let refusal = ToolDeclarationError.duplicateParameter(tool: "log_reading", parameter: "value")

    // MARK: - the DEFAULT table: the generator's init throws

    @Test("a bad default table throws the typed error from the generator's init — internal seam and public door")
    func aBadDefaultTableThrowsFromInit() {
        #expect(throws: Self.refusal) {
            try MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"]), tools: Self.twiceValue))
        }
        // The public init, with the weights of `MLXInstallTests` (absent;
        // the init reads nothing from them): the same typed error, on the
        // same line that handed the table.
        #expect(throws: Self.refusal) {
            try MLXReplyGenerator(model: LocalMindModel(weights: URL(filePath: "/nowhere/no-model")),
                                  tools: Self.twiceValue)
        }
    }

    /// The control: a clean table builds, on both inits — the 4w shape
    /// (`.empty`) and a tool with parameters.
    @Test("a clean default table builds: .empty, and a tool with parameters")
    func aCleanDefaultTableBuilds() throws {
        let clean = ToolTable([ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("")).tool])
        _ = try MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"]), tools: clean))
        _ = try MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"])))
        _ = try MLXReplyGenerator(model: LocalMindModel(weights: URL(filePath: "/nowhere/no-model")), tools: clean)
    }

    // MARK: - the PER-CALL table: openReply throws to the caller, and opens no run

    /// The words a caller reads: `ReplyFailure.engine` carrying the typed
    /// error's own sentence — the honest catch-all D-103 F-3 = A gave
    /// this seam, the case `ToolRounds.exceeded` already rides on this
    /// mind. Equatable, so an app can match it exactly.
    private static let perCallRefusal = ReplyFailure.engine(refusal.description)

    @Test("a bad per-call table throws ReplyFailure.engine with the typed error's words from openReply; no run opens")
    func aBadPerCallTableThrowsFromOpenReply() async throws {
        let source = ScriptedTokenSource(.tokens(["hi"]))
        let mind = try MLXReplyGenerator(source: source)
        let context = ReplyContext(transcript: "q", options: GenerationOptions(tools: Self.twiceValue))
        do {
            let run = try await mind.openReply(to: context)
            // The red state: a run opened. Drained so the count below is a
            // fact and not a race, and so nothing outlives this row.
            _ = await ReplyConformanceKit.drain(run)
            Issue.record("openReply opened a run on a table no mind can show")
        } catch let failure as ReplyFailure {
            #expect(failure == Self.perCallRefusal)
            #expect(failure.description == "tool 'log_reading' declares the parameter 'value' more than once")
        }
        #expect(source.askedAfter.isEmpty, "the source was never asked: no run was opened, nothing was rendered")
    }

    /// The order at the door: the table is the caller's own value and its
    /// error is true whatever the phone's state, so it is read BEFORE the
    /// heat and the verdict — a hot phone, or weights still arriving,
    /// must not hide a bug that will still be there when they clear.
    @Test("a bad per-call table is refused before the heat and the verdict: critical and absent hear the table's error")
    func theTableIsReadBeforeTheDeviceIsAsked() async throws {
        let source = ScriptedTokenSource(.tokens(["hi"]))
        source.makeUnavailable(.unavailable(.weightsAbsent))
        let mind = try MLXReplyGenerator(source: source, thermal: ScriptedThermalProvider(initial: .critical))
        await #expect(throws: Self.perCallRefusal) {
            _ = try await mind.openReply(to: ReplyContext(
                transcript: "q", options: GenerationOptions(tools: Self.twiceValue)))
        }
        // The same door with a clean call: the heat speaks, as AC-260 pins.
        await #expect(throws: ReplyFailure.tooHot(.critical)) {
            _ = try await mind.openReply(to: ReplyContext(
                transcript: "q", options: GenerationOptions(tools: .empty)))
        }
    }

    /// A clean per-call table still opens, and the run executes from it —
    /// `MLXToolsPerCallTests` proves the rest; this is the control beside
    /// the refusal.
    @Test("a clean per-call table opens a run as before")
    func aCleanPerCallTableOpens() async throws {
        let tool = ScriptedTool(name: "log_reading", parameters: [Self.value], plan: .answers("logged"))
        let source = ScriptedTokenSource(.events([.token("done"), .stopped(.complete)]))
        let run = try await MLXReplyGenerator(source: source).openReply(to: ReplyContext(
            transcript: "q", options: GenerationOptions(tools: ToolTable([tool.tool]))))
        #expect(await ReplyConformanceKit.drain(run) == [.token("done"), .finished(.complete)])
    }
}
