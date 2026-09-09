import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// 4v's contract against the REAL model (AC-234, AC-235, AC-236, AC-238):
/// the stop reason read from the vendor's `.info` event, the sampling
/// levers reaching the sampler, the window refusal before generation,
/// and the typed door. Gated exactly as `MLXMindLiveTests` is — on
/// `MMK_MLX_MODEL` and on `MLXRuntime.isAvailable` — because without a
/// metallib MLX aborts the process (D-061), and a skip that says so is
/// the least dishonest thing available.
@Suite("4v · the local mind honours the contract, when this machine has the model",
       .timeLimit(.minutes(5)), .serialized)
struct MLXContractLiveTests {

    private static var weights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The gate, and the reason the skip is loud (the 4h review): a
    /// silent early return prints "passed" for a proof that never ran.
    private static func live() -> URL? {
        guard let weights, MLXRuntime.isAvailable else {
            print("SKIPPED (no MMK_MLX_MODEL or no metallib) — set MMK_MLX_MODEL and run "
                  + "Scripts/metallib.sh to make this test REAL")
            return nil
        }
        return weights
    }

    private static let spoken = "Answer in one short sentence of plain prose. No markdown, no lists."

    // MARK: - AC-235: the stop reason is READ, not dropped

    @Test("a REAL reply that ends on its own is .finished(.complete)")
    func aWholeReplyEndsComplete() async throws {
        guard let weights = Self.live() else { return }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights), instructions: Self.spoken)
        let reply = try await mind.reply(to: ReplyContext(
            transcript: "What is the capital of Italy?",
            options: GenerationOptions(temperature: 0)))
        print("AC-235 complete · said: \(reply.text)")
        #expect(!reply.text.isEmpty)
        #expect(reply.stop == .complete, "the vendor said .stop; the seam must say .complete")
    }

    @Test("a REAL reply cut by a 3-token budget is .finished(.tokenBudget)")
    func aBudgetedReplyEndsOnTheBudget() async throws {
        guard let weights = Self.live() else { return }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights), instructions: Self.spoken)
        let reply = try await mind.reply(to: ReplyContext(
            transcript: "Tell me everything you know about the history of Rome.",
            options: GenerationOptions(maxTokens: 3, temperature: 0)))
        print("AC-235 budget · said: \(reply.text)")
        #expect(reply.stop == .tokenBudget, "the vendor said .length; the seam must say .tokenBudget")
    }

    // MARK: - AC-234: sampling reaches the vendor

    /// The determinism probe of AC-234, small: the same question twice
    /// under greedy, and twice under one seed. Byte-identical both times
    /// is the proof that `temperature` and `seed` reached the sampler —
    /// the full table with timings is `bakeoff determinism` (AC-244).
    @Test("temperature 0 twice, and seed 7 twice, are byte-identical")
    func theDeterminismProbe() async throws {
        guard let weights = Self.live() else { return }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights), instructions: Self.spoken)
        let question = "Name three capitals in Europe."

        func ask(_ options: GenerationOptions) async throws -> String {
            try await mind.reply(to: ReplyContext(transcript: question, options: options)).text
        }
        let greedy = GenerationOptions(maxTokens: 24, temperature: 0)
        let greedyOnce = try await ask(greedy)
        let greedyTwice = try await ask(greedy)
        print("AC-234 greedy · \(greedyOnce)")
        #expect(greedyOnce == greedyTwice, "greedy sampling must be byte-identical")

        let seeded = GenerationOptions(maxTokens: 24, temperature: 0.6, seed: 7)
        let seededOnce = try await ask(seeded)
        let seededTwice = try await ask(seeded)
        print("AC-234 seeded · \(seededOnce)")
        #expect(seededOnce == seededTwice, "the same seed must give the same bytes")
    }

    // MARK: - AC-236: the window, refused BEFORE generation

    @Test("a prompt longer than the model's window is .failed(.contextWindowExceeded), no token spoken")
    func aPromptLongerThanTheWindowIsRefused() async throws {
        guard let weights = Self.live() else { return }
        let model = LocalMindModel(weights: weights)
        guard let window = try await model.contextWindow() else {
            Issue.record("this model's config.json declares no max_position_embeddings"); return
        }
        print("AC-236 · the window is \(window) tokens")
        #expect(window > 0)

        // Every "7" is at least one token, so this prompt is longer than
        // the window whatever the tokenizer does with the spaces.
        let tooLong = String(repeating: "7 ", count: window + 512)
        let run = try await MLXReplyGenerator(model: model).openReply(to: tooLong)
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.failed(.contextWindowExceeded)],
                "refused before generation: one typed terminal and not one token")
    }

    // MARK: - AC-238's wiring: the door opens for a real install

    @Test("with the weights on disk and MLX runnable, the verdict is nil and the door opens")
    func theDoorOpensForARealInstall() async throws {
        guard let weights = Self.live() else { return }
        let model = LocalMindModel(weights: weights)
        let verdict = model.readiness()
        #expect(verdict == nil, "nothing is wrong with this machine: \(String(describing: verdict))")
        // A tree the Hub cache wrote before 4v has no manifest: the state
        // says so, and it still counts as installed.
        let state = model.installState()
        #expect(state == .installedUnverified || state == .installed, "\(state)")
        #expect(model.estimatedWorkingSetBytes() > 0)
        let run = try await MLXReplyGenerator(model: model).openReply(to: "hello")
        // Opened is the proof; the run is told to stop so nothing it owns
        // outlives the test.
        await run.cancel()
    }
}
