import Foundation
import FoundationModels
import Testing
@testable import MultiModalKit
import MultiModalKitTesting

/// The Apple mind's tool ADAPTER (4w piece 3, AC-223 / AC-225, D-101
/// F-1 = B, F-2 = A) — everything that can be proved WITHOUT the vendor's
/// model in the room.
///
/// The scripted snapshot source behind `AppleReplyGenerator` cannot
/// execute a vendor `Tool` — the framework executes tools inside a real
/// `LanguageModelSession`, and the seam sits above that — so these tests
/// hold the adapter in their hands: its name, its words, its schema,
/// that `call(arguments:)` reaches the `ReplyTool`, that a throw becomes
/// the sentence every mind writes, and that an empty table hands the
/// vendor nothing. The real session, with the real model, is
/// `AppleToolLiveTests`.
///
/// Runtime-gated on OS 26 the way every Apple test is: the vendor's
/// types do not exist below it.
@Suite("AC-223 · the Apple mind's tool adapter, without a model",
       .timeLimit(.minutes(1)))
struct AppleToolTests {

    /// The spike's one tool (F-3 = C): a no-argument read of today's
    /// session, answered from a stub.
    private static let answer = "Today's session is a forty minute tempo run. Readiness verdict: push."

    /// What the stub throws, with the words `ToolTable.call` and the
    /// vendor's `ToolCallError` both carry — `String(describing:)` of
    /// the error, which for a `CustomStringConvertible` is its
    /// `description`. `ScriptedTool.throwsError` throws the testing
    /// module's own error with the same words; this one exists so the
    /// test can BUILD the vendor's error by hand.
    private struct StubOffline: Error, CustomStringConvertible {
        let description = "the stub is offline"
    }

    // MARK: the adapter's shape

    @Test("the adapter wears the ReplyTool's name and description, verbatim")
    func nameAndDescriptionAreTheTools() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let tool = ReplyTool(name: "session", description: "reads today's training session") { _ in
            Self.answer
        }
        let adapter = AppleToolAdapter(tool)
        #expect(adapter.name == "session")
        #expect(adapter.description == "reads today's training session")
    }

    @Test("the schema the model is shown has no parameters — a no-argument read (§170)")
    func schemaHasNoProperties() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let adapter = AppleToolAdapter(ReplyTool(name: "session", description: "reads") { _ in "" })
        // `GenerationSchema` is `Codable`; its JSON is the honest witness
        // of what the model is shown. An object type with no properties.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(adapter.parameters))
        let schema = try #require(json as? [String: Any])
        #expect(schema["type"] as? String == "object", "schema: \(schema)")
        let properties = schema["properties"] as? [String: Any] ?? [:]
        #expect(properties.isEmpty, "a no-argument read shows no parameters: \(properties)")
    }

    // MARK: the call reaches the tool

    @Test("call(arguments:) reaches the ReplyTool with empty arguments and returns its answer")
    func callReachesTheTool() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", plan: .answers(Self.answer))
        let adapter = AppleToolAdapter(scripted.tool)
        let answer = try await adapter.call(arguments: AppleToolNoArguments())
        #expect(answer == Self.answer)
        #expect(scripted.calls == [[:]], "the spike's arguments are the empty dictionary")
    }

    // MARK: a throw, in the seam's words (AC-225)

    @Test("a tool's throw becomes the ToolCallFailure sentence every mind writes (AC-225)")
    func throwBecomesTheAgreedWords() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let adapter = AppleToolAdapter(scripted.tool)
        // The vendor's error, built the way the framework builds it: the
        // tool that threw and the error it threw.
        let vendor = LanguageModelSession.ToolCallError(
            tool: adapter, underlyingError: StubOffline())
        let failure = AppleReplyRun.toolFailure(from: vendor)
        #expect(failure == ToolCallFailure(tool: "session", reason: .threw("the stub is offline")))
        #expect(failure.description == "tool 'session' failed: the stub is offline")
        // The SAME sentence the scripted and MLX minds write for the same
        // tool, through `ToolTable.call` — one lookup rule, one sentence.
        let table = ToolTable([scripted.tool])
        let other = await table.call("session", arguments: [:])
        #expect(other == .failure(failure))
    }

    @Test("the run ends .failed(.engine(the sentence)) when the stream throws the vendor's ToolCallError")
    func runReportsTheToolFailure() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let vendor = LanguageModelSession.ToolCallError(
            tool: AppleToolAdapter(scripted.tool),
            underlyingError: StubOffline())
        let source = ScriptedSnapshotSource(.snapshotsThenThrow(["Let me check"], vendor))
        let generator = AppleReplyGenerator(source: source, tools: ToolTable([scripted.tool]))
        await #expect(throws: ReplyFailure.engine("tool 'session' failed: the stub is offline")) {
            _ = try await generator.reply(to: ReplyContext(transcript: "what is today's session?"))
        }
    }

    // MARK: the table at construction (F-2 = A)

    @Test("an empty table hands the vendor no tools (AC-227's plain path)")
    func emptyTableHandsOverNothing() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(AppleToolAdapter.adapters(for: .empty).isEmpty)
        let generator = AppleReplyGenerator()
        #expect(generator.tools.isEmpty)
        let source = generator.source as? FoundationModelSnapshots
        #expect(source?.tools.isEmpty == true, "the real source was built with no tools")
    }

    @Test("a table becomes one adapter per tool, in the table's order, and rides to the real source")
    func tableBecomesAdaptersInOrder() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let table = ToolTable([
            ReplyTool(name: "session", description: "reads today's session") { _ in "" },
            ReplyTool(name: "weather", description: "reads the sky") { _ in "" }
        ])
        let adapters = AppleToolAdapter.adapters(for: table)
        #expect(adapters.map(\.name) == ["session", "weather"])
        #expect(adapters.map(\.description) == ["reads today's session", "reads the sky"])
        let generator = AppleReplyGenerator(instructions: "speak briefly", tools: table)
        #expect(generator.tools.tools.map(\.name) == ["session", "weather"])
        let source = generator.source as? FoundationModelSnapshots
        #expect(source?.tools.tools.map(\.name) == ["session", "weather"])
    }

    // MARK: the vendor facts the session builder's comment cites (AC-227)

    /// `AppleReplyGenerator.session` says two measured things about the
    /// vendor; these two tests are the machine guarding them (§2/3), so
    /// a vendor update that changes either turns a comment's "measured"
    /// into a red instead of a stale sentence. Neither needs the model
    /// READY — a session is built, never asked.
    @Test("an empty table builds the SAME session as the pre-4w init(transcript:) (AC-227's Mac half)")
    func emptyTableBuildsThePre4wSession() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let transcript = Transcript(entries: [.instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "speak briefly"))],
            toolDefinitions: []))])
        let before4w = LanguageModelSession(transcript: transcript)
        let after4w = LanguageModelSession(tools: AppleToolAdapter.adapters(for: .empty),
                                           transcript: transcript)
        #expect(String(describing: before4w.transcript) == String(describing: after4w.transcript),
                "the vendor's default `tools: []` and an explicit `[]` must build one session")
    }

    @Test("the vendor fills the instructions entry's toolDefinitions from the tools it was handed")
    func vendorOwnsTheToolDefinitions() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let table = ToolTable([ReplyTool(name: "session", description: "reads today's session") { _ in "" }])
        // Written EMPTY here, exactly as `AppleReplyGenerator.session` writes it.
        let transcript = Transcript(entries: [.instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "speak briefly"))],
            toolDefinitions: []))])
        let session = LanguageModelSession(tools: AppleToolAdapter.adapters(for: table),
                                           transcript: transcript)
        let instructions = session.transcript.compactMap { entry -> Transcript.Instructions? in
            if case .instructions(let found) = entry { return found }
            return nil
        }
        let names = try #require(instructions.first).toolDefinitions.map(\.name)
        #expect(names == ["session"], "the vendor renders the handed tools itself: \(names)")
    }

    // MARK: the reentrancy law (§4.1, AC-226's belt)

    @Test("an answer that arrives after the call's task was cancelled goes nowhere")
    func lateAnswerIsDropped() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        // EVENT, not delay (§3.3): the test waits for the FACT that the
        // tool was entered, cancels, then lets the tool out.
        let entered = AsyncStream<Void>.makeStream()
        let scripted = ScriptedTool(name: "session", plan: .waitsForRelease(then: .answers(Self.answer)),
                                    onEnter: { _ in entered.continuation.yield() })
        let adapter = AppleToolAdapter(scripted.tool)
        let call = Task { try await adapter.call(arguments: AppleToolNoArguments()) }
        var gate = entered.stream.makeAsyncIterator()
        _ = await gate.next()
        call.cancel()
        scripted.release()
        let outcome = await call.result
        #expect(scripted.calls.count == 1, "the tool ran to its answer")
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}
