import Foundation
import MLXLMCommon
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE LOCAL MIND'S TOOL PIECES, PROVEN WITHOUT A MODEL (4w, AC-222).
//
// Everything `MLXTools.swift` and `LocalMind+Tools.swift` do is a pure
// function over strings and the vendor's plain values: the spec the
// model is shown, the flattening of a parsed call, the chat with the
// exchanges appended, and the sieve that turns decoded text into a
// `.toolCall`. None of it needs weights, so all of it runs on every
// machine — the live half (`MLXToolLiveTests`) proves only that the
// real model walks the path these rows pin.

// MARK: - the spec (AC-222; the prompt's `<tools>` block)

@Suite("4w · the spec the MLX mind renders for a tool")
struct ToolSpecTests {
    private let session = ReplyTool(name: "session",
                                    description: "Read today's training session.") { _ in "" }

    /// The fixture is the vendor's `ToolSpec` shape, byte for byte with
    /// keys sorted, because the template renders it with `tojson` and a
    /// key that moves is a prompt that moves (and AC-227's measurement
    /// with it).
    @Test("one tool renders as a function spec with an empty object of parameters")
    func specMatchesTheFixture() throws {
        let data = try JSONSerialization.data(
            withJSONObject: session.toolSpec, options: [.sortedKeys, .withoutEscapingSlashes])
        let rendered = try #require(String(data: data, encoding: .utf8))
        let fixture = #"{"function":{"description":"Read today's training session.","name":"session","#
            + #""parameters":{"properties":{},"type":"object"}},"type":"function"}"#
        #expect(rendered == fixture)
    }

    /// AC-227's Mac half is this row: NO tools must mean NO `tools:`
    /// argument — `nil`, which the template's `if tools` reads as absent
    /// — not an empty array the template would still branch on.
    @Test("an empty table renders nil, not []; a table renders one spec per tool")
    func emptyTableIsNil() throws {
        #expect(ToolTable.empty.toolSpecs == nil)
        let specs = try #require(ToolTable([session, session]).toolSpecs)
        #expect(specs.count == 2)
        #expect(specs.allSatisfy { ($0["type"] as? String) == "function" })
    }

    /// AC-270: the model is SHOWN the parameters — the JSON-schema object
    /// every chat template of this family reads: `properties` with a
    /// `type` and a `description` each, and `required` listing the ones
    /// the model may not leave out. Keys sorted, byte for byte, for the
    /// same reason as the row above.
    @Test("a tool with parameters renders them as properties and required (AC-270)")
    func parametersAreRendered() throws {
        let logWeight = ReplyTool(
            name: "log_weight",
            description: "Record today's body weight.",
            parameters: [
                ToolParameter(name: "kg", description: "the weight in kilograms", kind: .number),
                ToolParameter(name: "note", description: "an optional note", kind: .string, isRequired: false),
                ToolParameter(name: "sets", description: "how many", kind: .integer),
                ToolParameter(name: "sync", description: "also to Health", kind: .boolean, isRequired: false)
            ]) { _ in "" }
        let data = try JSONSerialization.data(
            withJSONObject: logWeight.toolSpec, options: [.sortedKeys, .withoutEscapingSlashes])
        let rendered = try #require(String(data: data, encoding: .utf8))
        let fixture = #"{"function":{"description":"Record today's body weight.","name":"log_weight","parameters":{"#
            + #""properties":{"kg":{"description":"the weight in kilograms","type":"number"},"#
            + #""note":{"description":"an optional note","type":"string"},"#
            + #""sets":{"description":"how many","type":"integer"},"#
            + #""sync":{"description":"also to Health","type":"boolean"}},"#
            + #""required":["kg","sets"],"type":"object"}},"type":"function"}"#
        #expect(rendered == fixture)
    }

    /// A tool without parameters renders EXACTLY the spike's spec: no
    /// `required` key appears, so AC-227's measured prompt is unchanged.
    @Test("no parameters renders no required key — the spike's bytes (AC-277)")
    func noParametersNoRequired() throws {
        let data = try JSONSerialization.data(
            withJSONObject: session.toolSpec, options: [.sortedKeys, .withoutEscapingSlashes])
        let rendered = try #require(String(data: data, encoding: .utf8))
        #expect(!rendered.contains("required"))
    }
}

// MARK: - the mapping (the contract's `ToolValue`, 4z)

@Suite("4z · a parsed call's arguments become the contract's values — scalars typed, containers as JSON text")
struct ToolCallMappingTests {
    @Test("each JSON scalar keeps its kind; containers become sorted JSON text",
          arguments: [
            (JSONValue.string("today"), ToolValue.string("today")),
            (.int(40), .integer(40)),
            (.double(0.25), .number(0.25)),
            (.bool(true), .boolean(true)),
            (.bool(false), .boolean(false)),
            (.null, .null),
            (.array([.int(1), .string("b")]), .string(#"[1,"b"]"#)),
            (.object(["zebra": .int(1), "apple": .string("x")]), .string(#"{"apple":"x","zebra":1}"#))
          ] as [(JSONValue, ToolValue)])
    func maps(value: JSONValue, expected: ToolValue) {
        #expect(ToolValue(json: value) == expected)
    }

    @Test("the way back keeps the kind, so the model's own record of its call is what it wrote")
    func roundTrip() {
        for value in [JSONValue.string("today"), .int(40), .double(0.25), .bool(true), .null] {
            #expect(ToolValue(json: value).json == value)
        }
    }

    @Test("the vendor's ToolCall becomes the seam's request, name kept, arguments typed")
    func fromTheVendorsCall() {
        let call = ToolCall(function: .init(
            name: "session", arguments: ["day": .string("today"), "minutes": .int(40)]))
        #expect(ToolCallRequest(vendor: call)
                == ToolCallRequest(name: "session", arguments: ["day": "today", "minutes": 40]))
    }

    @Test("a call with no arguments is a request with none — the spike's read")
    func noArguments() {
        let call = ToolCall(function: .init(name: "session", arguments: [String: JSONValue]()))
        #expect(ToolCallRequest(vendor: call) == ToolCallRequest(name: "session"))
    }
}

// MARK: - the chat with exchanges (the next round's prompt)

@Suite("4w · the exchanges are appended after the question, in the template's roles")
struct ToolExchangeMessagesTests {
    @Test("no exchanges renders exactly the 4r chat")
    func noExchangesIsThe4rChat() {
        let before = MLXTokenSource.messages(spoken: "speak", asked: "hi", past: [])
        let after = MLXTokenSource.messages(spoken: "speak", asked: "hi", past: [], exchanges: [])
        #expect(before.map(\.role) == after.map(\.role))
        #expect(before.map(\.content) == after.map(\.content))
        #expect(after.map(\.role) == [.system, .user])
    }

    @Test("one exchange is an assistant turn carrying the call, then a tool turn carrying the answer")
    func oneExchangeIsTwoTurns() throws {
        let exchange = ToolExchange(
            request: ToolCallRequest(name: "session", arguments: ["day": "today"]),
            answer: "Today is a 40 minute easy run, readiness 71.")
        let messages = MLXTokenSource.messages(
            spoken: nil, asked: "What is today's session?", past: [], exchanges: [exchange])
        #expect(messages.map(\.role) == [.user, .assistant, .tool])
        // The assistant turn's words are EMPTY — what it said before the
        // call was already spoken; the call rides as metadata.
        #expect(messages[1].content == "")
        #expect(messages[2].content == exchange.answer)
        // The vendor's own message generator is what the template reads;
        // it must see the call by name with the arguments as it wrote them.
        let raw = DefaultMessageGenerator().generate(message: messages[1])
        let calls = try #require(raw["tool_calls"] as? [[String: any Sendable]])
        let function = try #require(calls.first?["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "session")
        #expect((function["arguments"] as? [String: any Sendable])?["day"] as? String == "today")
    }

    @Test("two exchanges keep their order — the template pairs a call with its result by order")
    func twoExchangesKeepOrder() {
        let first = ToolExchange(request: ToolCallRequest(name: "a"), answer: "one")
        let second = ToolExchange(request: ToolCallRequest(name: "b"), answer: "two")
        let messages = MLXTokenSource.messages(spoken: nil, asked: "q", past: [], exchanges: [first, second])
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool])
        #expect(messages.filter { $0.role == .tool }.map(\.content) == ["one", "two"])
    }
}

// MARK: - the sieve (the vendor's parser over our gated pieces)

/// The pieces below are what the detokenizer hands the sieve for the
/// `<tool_call>` JSON format the vendor infers for these weights. The
/// events must come out in the order the vendor's own text loop keeps:
/// the text that was ready, then every complete call.
@Suite("4w · the sieve turns decoded pieces into text and .toolCall events")
struct ToolCallSieveTests {
    private func sieve() -> ToolCallSieve { ToolCallSieve(format: .json, specs: nil) }

    @Test("plain text passes through as tokens, one per piece")
    func plainTextPasses() {
        let sieve = sieve()
        #expect(sieve.admit("Today") == [.token("Today")])
        #expect(sieve.admit(" is") == [.token(" is")])
        #expect(sieve.finish() == [])
    }

    @Test("a tagged call is collected silently and emitted whole when its end tag arrives")
    func aTaggedCallIsOneEvent() {
        let sieve = sieve()
        var events: [TokenEvent] = []
        for piece in ["<tool", "_call>\n", #"{"name": "session","#, #" "arguments": {}}"#, "\n</tool_call>"] {
            events += sieve.admit(piece)
        }
        #expect(events == [.toolCall(ToolCallRequest(name: "session"))],
                "nothing of the call's JSON is ever spoken; the call is one event")
        #expect(sieve.finish() == [])
    }

    @Test("words before the call are spoken; the call's arguments arrive typed")
    func wordsThenCallWithArguments() {
        let sieve = sieve()
        var events: [TokenEvent] = []
        for piece in ["Let me check. ", "<tool_call>",
                      #"{"name": "session", "arguments": {"day": "today", "n": 2}}"#,
                      "</tool_call>"] {
            events += sieve.admit(piece)
        }
        #expect(events == [
            .token("Let me check. "),
            .toolCall(ToolCallRequest(name: "session", arguments: ["day": "today", "n": 2]))
        ])
    }

    /// The vendor's end-of-sequence path: a format whose end tag never
    /// arrives as text, or a call cut at the end. `finish()` is where the
    /// buffered call is parsed — the loop calls it on `.info`, before
    /// `.stopped`, so the run sees the call before the round ends.
    @Test("a call still buffered at end of sequence is parsed by finish()")
    func aBufferedCallIsParsedAtTheEnd() {
        let sieve = sieve()
        #expect(sieve.admit("<tool_call>") == [])
        #expect(sieve.admit(#"{"name": "session", "arguments": {}}"#) == [])
        #expect(sieve.finish() == [.toolCall(ToolCallRequest(name: "session"))])
    }

    @Test("a brace that was not a call is text after all, flushed at the end")
    func aStrayBraceIsText() {
        let sieve = sieve()
        #expect(sieve.admit("set {") == [.token("set ")])
        #expect(sieve.finish() == [.token("{")])
    }
}
