import Foundation
import Testing
@testable import MultiModalKitMLX

/// AC-125: the reply is made speakable at the TOKEN, not the string.
///
/// Every test here runs with no weights, no metallib and no GPU — the
/// gate is integer comparison over token ids. That is the point of
/// D-062's F-2 = B: the part that had to be right is the part that needs
/// nothing to prove.
@Suite("AC-125 · the think gate")
struct ThinkGateTests {

    /// Ordinary words either side of a thought the person must never hear.
    private static let script = [
        11,                 // "Rome"
        151667,             // <think>
        900, 901, 902,      // the model's private deliberation
        151668,             // </think>
        12,                 // "is"
        13,                 // "the capital."
    ]
    private static let tokens = ThinkTokens(open: 151667, close: 151668)

    private static func admitted(_ ids: [Int],
                                 through gate: inout ThinkGate) -> [Int] {
        ids.filter { gate.admits($0) }
    }

    @Test("a DEFIANT <think> is swallowed — layer 1 is a convention, this is the net")
    func defianceIsSwallowed() {
        var gate = ThinkGate(Self.tokens)
        let out = Self.admitted(Self.script, through: &gate)
        #expect(out == [11, 12, 13])
        #expect(gate.isSwallowing == false, "the thought was closed")
    }

    /// THE CONTROL, and it is stricter than it first was.
    ///
    /// The first version asserted only that the gated output DIFFERED
    /// from the ungated one. A mutation run neutered the gate and this
    /// test still passed — the close marker alone was enough to make the
    /// two differ. A control that survives the mutation it exists to
    /// catch is worthless, so both halves are now EXACT.
    ///
    /// The ungated half runs the same code path with a foreign
    /// vocabulary, rather than skipping the gate entirely: that proves
    /// the gate acts on THESE ids and not on tokens in general.
    @Test("the removed-gate control — a foreign vocabulary lets the reasoning through")
    func withoutTheGateReasoningEscapes() {
        var foreign = ThinkGate(ThinkTokens(open: 7, close: 8))
        #expect(Self.admitted(Self.script, through: &foreign) == Self.script,
                "a gate for another model's markers must change nothing")
        var gate = ThinkGate(Self.tokens)
        #expect(Self.admitted(Self.script, through: &gate) == [11, 12, 13],
                "and the right markers must remove exactly the reasoning")
    }

    @Test("the markers themselves never reach the mouth — punctuation, not words")
    func markersAreNeverSpoken() {
        var gate = ThinkGate(Self.tokens)
        let out = Self.admitted(Self.script, through: &gate)
        #expect(!out.contains(151667))
        #expect(!out.contains(151668))
    }

    @Test("an unclosed thought swallows to the end, and SAYS that it is still holding")
    func unclosedThoughtRunsToTheEnd() {
        var gate = ThinkGate(Self.tokens)
        let out = Self.admitted([11, 151667, 900, 901], through: &gate)
        #expect(out == [11])
        #expect(gate.isSwallowing, "the instrument reports its own state")
    }

    @Test("a template that already opened the thought starts inside it")
    func startingInsideAThought() {
        var gate = ThinkGate(Self.tokens, startingInsideThought: true)
        let out = Self.admitted([900, 151668, 12], through: &gate)
        #expect(out == [12])
    }

    @Test("a stray close with no open is harmless, not a crash")
    func strayCloseIsHarmless() {
        var gate = ThinkGate(Self.tokens)
        let out = Self.admitted([11, 151668, 12], through: &gate)
        #expect(out == [11, 12])
    }
}

/// AC-125's other half: the ids are READ, never hard-coded.
@Suite("AC-125 · the ids come from the model, not from me")
struct ThinkTokensTests {

    private static func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tok-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test("both markers present — the two ids are read from the vocabulary")
    func readsBothMarkers() throws {
        let url = try Self.write("""
        {"added_tokens_decoder": {
            "151667": {"content": "<think>"},
            "151668": {"content": "</think>"},
            "151643": {"content": "<|endoftext|>"}
        }}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ThinkTokens.read(fromTokenizerConfigAt: url)
                == ThinkTokens(open: 151667, close: 151668))
    }

    @Test("a model that does not reason out loud is nil, not an error")
    func noMarkersIsNotAFailure() throws {
        let url = try Self.write("""
        {"added_tokens_decoder": {"151643": {"content": "<|endoftext|>"}}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ThinkTokens.read(fromTokenizerConfigAt: url) == nil)
    }

    /// The loud failure AC-125 asks for. Half a vocabulary is the case
    /// where a guess would be silently wrong, and silently wrong here is
    /// a phone speaking its own deliberation.
    @Test("HALF a vocabulary throws rather than guesses")
    func halfAVocabularyThrows() throws {
        let url = try Self.write("""
        {"added_tokens_decoder": {"151667": {"content": "<think>"}}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ThinkTokensFailure.self) {
            _ = try ThinkTokens.read(fromTokenizerConfigAt: url)
        }
    }

    @Test("a file that is not a tokenizer configuration is refused")
    func rubbishIsRefused() throws {
        let url = try Self.write("[1, 2, 3]")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ThinkTokensFailure.self) {
            _ = try ThinkTokens.read(fromTokenizerConfigAt: url)
        }
    }

    /// The real vocabulary, when the machine running the suite has one.
    /// Config only — this reads a small JSON file, never the 334 MB.
    @Test("the REAL model's config yields 151667/151668 (model config; skips if absent)")
    func theRealVocabulary() throws {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return }
        let url = URL(filePath: dir).appending(path: "tokenizer_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        #expect(try ThinkTokens.read(fromTokenizerConfigAt: url)
                == ThinkTokens(open: 151667, close: 151668))
    }
}
