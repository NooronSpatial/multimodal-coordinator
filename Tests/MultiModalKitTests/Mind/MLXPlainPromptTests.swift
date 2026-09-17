import Foundation
import MLXLMCommon
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE PLAIN PATH'S WHOLE PROMPT, CAPTURED (4z, SPEC §195 AC-272; D-110
// F-2 = A).
//
// 4w measured what a tool costs a reply that never uses it (§67), and
// its only byte fixture is the `<tools>` block. This row keeps the OTHER
// promise: a call with no table, on a generator with none, renders
// exactly the prompt it rendered before 4z touched the MLX mind. The
// bytes were captured (the "before" file) BEFORE any of PIECE 2's
// commits — not before every 4z commit that changed
// `Sources/MultiModalKitMLX`: piece 1 (4f8b350) had already changed the
// MLX run's arm (`MLXReplyGenerator.execute`, which runs only after a
// call) but not the prompt-rendering path — `LocalMind.swift`,
// `LocalMind+Tools.swift` and `MLXTools.swift` were untouched since
// 4w/4y — and the capture's 123 chars / 23 tokens match 4w's plain
// baseline. The same row renders the same bytes after, so "the plain
// path is unchanged" is a diff, not a sentence.
//
// The prompt is built by the SAME code `MLXTokenSource.generate` runs:
// the resolved settings, the table resolved for the call (`tools(for:)`,
// F-2 = A — `.empty` here, which renders `nil`, AC-227's rule), and
// `MLXTokenSource.userInput` — the one static function that builds the
// chat in the template's roles, the specs and the think switch for the
// vendor's `prepare`. The "before" file was rendered from a hand copy of
// that path at `b0798db` (the function did not exist yet); the "after"
// row renders from the function itself, so the compare is between the
// old path and the real new one, not two copies. Decoded back to text
// by the same tokenizer, with the vendor's token count beside it.
//
// Gated on `MMK_MLX_MODEL` and the metallib, and the skip is LOUD (the
// 4h review): a silent early return prints "passed" for a proof that
// never ran. With `MMK_CAPTURE_PROMPT=<path>` the row WRITES the render
// there instead of comparing — the one-off that made the files in
// `docs/evidence/4z/`; a normal run is read-only.

@Suite("AC-272 · the plain path's whole prompt is the same bytes before and after 4z, when this machine has the model",
       .timeLimit(.minutes(5)), .serialized)
struct MLXPlainPromptTests {

    private static var weights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func live() -> URL? {
        guard let weights, MLXRuntime.isAvailable else {
            print("SKIPPED (no MMK_MLX_MODEL or no metallib) — set MMK_MLX_MODEL and run "
                  + "Scripts/metallib.sh to make this test REAL")
            return nil
        }
        return weights
    }

    /// §67's plain question — the one that needs no tool.
    private static let plainQuestion = "Name three capitals in Europe and one fact about each."

    /// Where the captures live, found from this file: the package root is
    /// four directories up from `Tests/MultiModalKitTests/Mind/`.
    private static var evidence: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/evidence/4z")
    }
    private static let before = evidence.appending(path: "plain-prompt-before.txt")
    private static let after = evidence.appending(path: "plain-prompt-after.txt")

    /// The whole prompt for ONE fixed chat: no instruction (§67's default),
    /// no history, no table on the call, none on the generator — rendered
    /// by the code `MLXTokenSource.generate` runs, and decoded back to
    /// text. The file's shape: the vendor's token count, a rule, the text.
    private static func render(weights: URL) async throws -> String {
        let model = LocalMindModel(weights: weights)
        let container = try await model.ensureModelLoaded()
        let source = MLXTokenSource(model: model, instructions: nil, maxTokens: 1024)
        let context = ReplyContext(transcript: plainQuestion)
        let settings = MLXGenerationSettings(
            options: context.options, instructions: source.instructions, maxTokens: source.maxTokens)
        // The table resolved for THIS call, the way generate resolves it
        // (F-2 = A): nothing on the call, nothing on the source → `.empty`
        // → `nil` specs (AC-227). Pinned here too, so a moved byte below
        // can be read against a moved rule.
        let turnTools = source.tools(for: context)
        #expect(turnTools == .empty)
        let specs = turnTools.toolSpecs
        #expect(specs == nil, "no specs reach the vendor on the plain path")
        let asked = context.transcript
        let past = context.history
        return try await container.perform { (model: ModelContext) in
            let input = try await model.processor.prepare(
                input: MLXTokenSource.userInput(spoken: settings.instructions, asked: asked,
                                                past: past, exchanges: [], specs: specs))
            let ids = input.text.tokens.asArray(Int.self)
            return "tokens: \(ids.count)\n---\n" + model.tokenizer.decode(tokenIds: ids)
        }
    }

    private static func file(_ url: URL, _ which: String) throws -> Data {
        try #require(try? Data(contentsOf: url),
                     "the \(which)-capture is missing at \(url.path): run once with MMK_CAPTURE_PROMPT set to it")
    }

    @Test("no table on the call, none on the generator: the prompt is the bytes captured before 4z, and after")
    func thePlainPromptIsTheCapturedBytes() async throws {
        guard let weights = Self.live() else { return }
        let rendered = try await Self.render(weights: weights)
        let tokens = rendered.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "?"
        print("AC-272 live · the plain prompt: \(tokens), \(rendered.utf8.count) bytes")

        if let capture = ProcessInfo.processInfo.environment["MMK_CAPTURE_PROMPT"] {
            try Data(rendered.utf8).write(to: URL(filePath: capture))
            print("AC-272 live · CAPTURED to \(capture) — this run compared nothing")
            return
        }
        let before = try Self.file(Self.before, "before")
        let after = try Self.file(Self.after, "after")
        #expect(Data(rendered.utf8) == before,
                "the plain path's prompt changed since the before-capture — AC-272 is broken:\n\(rendered)")
        #expect(Data(rendered.utf8) == after,
                "the plain path's prompt changed since the after-capture:\n\(rendered)")
        #expect(before == after, "the two captures in docs/evidence/4z are not the same bytes")
        print("AC-272 live · before == after == this render: \(before == after && Data(rendered.utf8) == before)")
    }
}
