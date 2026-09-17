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
// bytes were captured BEFORE any commit that changed
// `Sources/MultiModalKitMLX` (the "before" file), and the same row
// renders the same bytes after — so "the plain path is unchanged" is a
// diff, not a sentence.
//
// The prompt is built the way `MLXTokenSource.generate` builds it: the
// resolved settings, the chat in the template's roles, the table's
// specs (`nil` for none — AC-227's rule), and the vendor's own
// `prepare`. Decoded back to text by the same tokenizer, with the
// vendor's token count beside it.
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

    /// The whole prompt for ONE fixed chat: no instruction (§67's default),
    /// no history, no table on the call, none on the generator — rendered
    /// as `MLXTokenSource.generate` renders it, and decoded back to text.
    /// The file's shape: the vendor's token count, a rule, the text.
    private static func render(weights: URL) async throws -> String {
        let model = LocalMindModel(weights: weights)
        let container = try await model.ensureModelLoaded()
        let source = MLXTokenSource(model: model, instructions: nil, maxTokens: 1024)
        let context = ReplyContext(transcript: plainQuestion)
        let settings = MLXGenerationSettings(
            options: context.options, instructions: source.instructions, maxTokens: source.maxTokens)
        // The generator's table, as the source reads it for every call
        // at this commit: `.empty`, which renders `nil` (AC-227).
        let specs = source.tools.toolSpecs
        let asked = context.transcript
        let past = context.history
        return try await container.perform { (model: ModelContext) in
            let messages = MLXTokenSource.messages(
                spoken: settings.instructions, asked: asked, past: past, exchanges: [])
            let input = try await model.processor.prepare(input: UserInput(
                chat: messages, tools: specs, additionalContext: ["enable_thinking": false]))
            let ids = input.text.tokens.asArray(Int.self)
            return "tokens: \(ids.count)\n---\n" + model.tokenizer.decode(tokenIds: ids)
        }
    }

    @Test("no table on the call, none on the generator: the prompt is the bytes captured before 4z")
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
        let before = try #require(
            try? Data(contentsOf: Self.before),
            "the before-capture is missing at \(Self.before.path): run once with MMK_CAPTURE_PROMPT set to it")
        #expect(Data(rendered.utf8) == before,
                "the plain path's prompt changed since the capture — AC-272 is broken:\n\(rendered)")
    }
}
