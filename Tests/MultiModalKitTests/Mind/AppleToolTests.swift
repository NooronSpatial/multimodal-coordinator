import Foundation
import FoundationModels
import Testing
@testable import MultiModalKit
import MultiModalKitTesting

/// The Apple mind's tool ADAPTER (4w piece 3, AC-223 / AC-225; 4z piece
/// 3, AC-269 / AC-270 / AC-275 / AC-276 / AC-289 — D-110 F-1 = A, F-2 = A,
/// F-4 = B, F-10 B-ii, F-11 B, F-13 d) — everything that can be proved
/// WITHOUT the vendor's model in the room.
///
/// The scripted snapshot source behind `AppleReplyGenerator` cannot
/// execute a vendor `Tool` — the framework executes tools inside a real
/// `LanguageModelSession`, and the seam sits above that — so these tests
/// hold the adapter in their hands: its name, its words, the SCHEMA it
/// builds from the declaration, the typed answer it reads into the
/// door's arguments, that a throw is answered in words, that the flag is
/// enforced with the call's yes, and that the table is resolved per
/// call. The real session, with the real model, is `AppleToolLiveTests`.
///
/// Runtime-gated on OS 26 the way every Apple test is: the vendor's
/// types do not exist below it.
@Suite("AC-223 / AC-270 · the Apple mind's tool adapter, without a model",
       .timeLimit(.minutes(1)))
struct AppleToolTests {

    /// The spike's one tool (F-3 = C): a no-argument read of today's
    /// session, answered from a stub.
    static let answer = "Today's session is a forty minute tempo run. Readiness verdict: push."

    /// What the stub throws, with the words `ToolTable.invoke` and the
    /// vendor's `ToolCallError` both carry — `String(describing:)` of
    /// the error, which for a `CustomStringConvertible` is its
    /// `description`. `ScriptedTool.throwsError` throws the testing
    /// module's own error with the same words; this one exists so the
    /// test can BUILD the vendor's error by hand.
    private struct StubOffline: Error, CustomStringConvertible {
        let description = "the stub is offline"
    }

    /// The model's answer with NO arguments — what the vendor hands a
    /// tool whose schema has no properties.
    @available(macOS 26.0, iOS 26.0, *)
    static func noArguments() throws -> GeneratedContent {
        try GeneratedContent(json: "{}")
    }

    /// A tool with the four kinds and one optional parameter — AC-270's
    /// declaration, in the app's own sentences.
    static let fourKinds = ReplyTool(
        name: "log_reading",
        description: "records a reading",
        parameters: [
            ToolParameter(name: "kg", description: "the weight in kilograms", kind: .number, isRequired: true),
            ToolParameter(name: "note", description: "a short note", kind: .string, isRequired: false),
            ToolParameter(name: "reps", description: "how many", kind: .integer, isRequired: true),
            ToolParameter(name: "fasted", description: "before breakfast", kind: .boolean, isRequired: true)
        ],
        requiresConfirmation: false) { _ in "recorded" }

    /// The schema as JSON — `GenerationSchema` is `Codable`, and its
    /// JSON is the honest witness of what the model is shown.
    @available(macOS 26.0, iOS 26.0, *)
    static func json(of schema: GenerationSchema) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        return try #require(object as? [String: Any], "a schema encodes to an object")
    }

    // MARK: the adapter's shape

    @Test("the adapter wears the ReplyTool's name and description, verbatim")
    func nameAndDescriptionAreTheTools() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let adapter = try AppleToolAdapter(ReplyTool(name: "session", description: "reads today's session",
                                                     parameters: [], requiresConfirmation: false) { _ in "" })
        #expect(adapter.name == "session")
        #expect(adapter.description == "reads today's session")
    }

    @Test("a tool with no parameters shows the spike's schema, unchanged (AC-270)")
    func noParametersShowsTheSpikesSchema() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let adapter = try AppleToolAdapter(ReplyTool(name: "session", description: "reads",
                                                     parameters: [], requiresConfirmation: false) { _ in "" })
        let shown = try Self.json(of: adapter.parameters)
        #expect(shown["type"] as? String == "object", "schema: \(shown)")
        let properties = shown["properties"] as? [String: Any] ?? [:]
        #expect(properties.isEmpty, "a no-argument read shows no parameters: \(properties)")
        // Byte for byte the spike's: the same schema the @Generable empty
        // struct yields, so 4w's measured plain path is untouched.
        // The vendor encodes its dictionaries in no fixed order (measured:
        // two encodings of one schema differ), so the bytes are compared
        // with sorted keys — the only honest byte comparison there is.
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        let spike = try sorted.encode(AppleToolNoArguments.generationSchema)
        let now = try sorted.encode(adapter.parameters)
        #expect(spike == now, "the no-parameter schema is the spike's, unchanged")
    }

    // MARK: the call reaches the tool, through the door

    @Test("call(arguments:) reaches the ReplyTool with the typed arguments and returns its answer")
    func callReachesTheTool() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "log_reading",
                                    parameters: [ToolParameter(name: "kg", description: "the weight",
                                                               kind: .number, isRequired: true)],
                                    plan: .answers("recorded"))
        let adapter = try AppleToolAdapter(scripted.tool)
        let answer = try await adapter.call(arguments: try GeneratedContent(json: "{\"kg\": 83.5}"))
        #expect(answer == "recorded")
        #expect(scripted.calls == [ToolArguments(["kg": 83.5])], "a number arrives as a number, through the door")
    }

    @Test("a missing required argument never reaches the body; the model reads the door's sentence (AC-273)")
    func missingArgumentIsAnsweredInWords() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "log_reading",
                                    parameters: [ToolParameter(name: "kg", description: "the weight",
                                                               kind: .number, isRequired: true)],
                                    plan: .answers("recorded"))
        let adapter = try AppleToolAdapter(scripted.tool)
        let words = try await adapter.call(arguments: try Self.noArguments())
        let table = ToolTable([scripted.tool])
        let expected = await table.invoke("log_reading", arguments: .empty).wordsForModel
        #expect(words == expected, "the same sentence the other minds read")
        #expect(words.contains("missing"), "words: \(words)")
        #expect(scripted.calls.isEmpty, "the body never ran")
    }

    // MARK: a throw, in the seam's words (AC-225, AC-276 — F-4 = B)

    @Test("a tool's throw becomes the ToolCallFailure sentence every mind writes (AC-225)")
    func throwBecomesTheAgreedWords() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let adapter = try AppleToolAdapter(scripted.tool)
        // The vendor's error, built the way the framework builds it: the
        // tool that threw and the error it threw.
        let vendor = LanguageModelSession.ToolCallError(
            tool: adapter, underlyingError: StubOffline())
        let failure = AppleReplyRun.toolFailure(from: vendor)
        #expect(failure == ToolCallFailure(tool: "session", reason: .threw("the stub is offline")))
        #expect(failure.description == "tool 'session' failed: the stub is offline")
        // The SAME sentence the scripted and MLX minds write for the same
        // tool, through `ToolTable.invoke` — one door, one sentence.
        let table = ToolTable([scripted.tool])
        let other = await table.invoke("session", arguments: .empty).result
        #expect(other == .failure(failure))
    }

    @Test("a throw is answered in words: call(arguments:) returns the sentence and does not throw (AC-276, F-4 = B)")
    func throwIsAnsweredInWords() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let adapter = try AppleToolAdapter(scripted.tool)
        let words = try await adapter.call(arguments: try Self.noArguments())
        #expect(words == "tool 'session' failed: the stub is offline",
                "the model reads the sentence and goes on; the reply ends .finished")
        #expect(scripted.calls == [.empty], "the body ran once, through the door")
    }

    @Test("toolFailure(from:) still carries a typed value whole — one wrap, never two")
    func typedFailureIsCarriedWhole() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let typed = ToolCallFailure(tool: "session", reason: .threw("the stub is offline"))
        let adapter = try? AppleToolAdapter(ReplyTool(name: "session", description: "reads",
                                                      parameters: [], requiresConfirmation: false) { _ in "" })
        guard let adapter else { Issue.record("a well-formed tool builds an adapter"); return }
        let vendor = LanguageModelSession.ToolCallError(tool: adapter, underlyingError: typed)
        let failure = AppleReplyRun.toolFailure(from: vendor)
        #expect(failure == typed)
        #expect(failure.description == "tool 'session' failed: the stub is offline")
    }

    // MARK: the flag and the call's yes (F-10 B-ii, AC-279 B on this mind)

    @Test("a flagged tool with no yes on the call is told to ask; with the name confirmed it runs once")
    func flagIsEnforcedWithTheCallsYes() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let scripted = ScriptedTool(name: "session", requiresConfirmation: true, plan: .answers(Self.answer))
        let asked = try await AppleToolAdapter(scripted.tool).call(arguments: try Self.noArguments())
        let expected = await ToolTable([scripted.tool]).invoke("session", arguments: .empty).wordsForModel
        #expect(asked == expected && asked.contains("confirmation"), "told to ask: \(asked)")
        #expect(scripted.calls.isEmpty, "the door refused before the body")
        let confirmed = try AppleToolAdapter(scripted.tool, confirmed: ["session"])
        let answer = try await confirmed.call(arguments: try Self.noArguments())
        #expect(answer == Self.answer)
        #expect(scripted.calls == [.empty], "the body ran exactly once, after the yes")
    }

    // MARK: the vendor facts the session builder's comment cites (AC-227)

    /// `AppleReplyGenerator.session` says two measured things about the
    /// vendor; these two tests are the machine guarding them (§2/3), so
    /// a vendor update that changes either turns a comment's "measured"
    /// into a red instead of a stale sentence. Neither needs the model
    /// READY — a session is built, never asked.
    @Test("an empty table builds the SAME session as the pre-4w init(transcript:) (AC-227's Mac half)")
    func emptyTableBuildsThePre4wSession() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let transcript = Transcript(entries: [.instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "speak briefly"))],
            toolDefinitions: []))])
        let before4w = LanguageModelSession(transcript: transcript)
        let after4w = LanguageModelSession(tools: try AppleToolAdapter.adapters(for: .empty),
                                           transcript: transcript)
        #expect(String(describing: before4w.transcript) == String(describing: after4w.transcript),
                "the vendor's default `tools: []` and an explicit `[]` must build one session")
    }

    @Test("the vendor fills the instructions entry's toolDefinitions from the tools it was handed")
    func vendorOwnsTheToolDefinitions() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let table = ToolTable([ReplyTool(name: "session", description: "reads today's session",
                                         parameters: [], requiresConfirmation: false) { _ in "" }])
        // Written EMPTY here, exactly as `AppleReplyGenerator.session` writes it.
        let transcript = Transcript(entries: [.instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "speak briefly"))],
            toolDefinitions: []))])
        let session = LanguageModelSession(tools: try AppleToolAdapter.adapters(for: table),
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
        let adapter = try AppleToolAdapter(scripted.tool)
        let call = Task { try await adapter.call(arguments: try Self.noArguments()) }
        var gate = entered.stream.makeAsyncIterator()
        _ = await gate.next()
        call.cancel()
        scripted.release()
        let outcome = await call.result
        #expect(scripted.calls.count == 1, "the tool ran to its answer (F-5 A: the body is shielded)")
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}
