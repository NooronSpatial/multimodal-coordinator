import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-232 / AC-233 / AC-234 (the MLX half): the caller's per-call
/// `GenerationOptions` are RESOLVED against the source's own settings by
/// one pure value, `MLXGenerationSettings`, before anything touches the
/// vendor. `nil` on an option means "the source's own" (F-1 = A, D-103),
/// and that rule is pinned here, one lever per test, with no weights.
@Suite("AC-232..234 · per-call options resolve against the source's own settings")
struct MLXGenerationSettingsTests {

    // MARK: - AC-232: instructions

    @Test("per-call instructions replace the source's own for that call")
    func perCallInstructionsWin() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(instructions: "Propose a session as JSON."),
            instructions: "You are speaking aloud.",
            maxTokens: 1024)
        #expect(settings.instructions == "Propose a session as JSON.")
    }

    @Test("nil instructions keep the source's own")
    func nilInstructionsKeepTheSourcesOwn() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(),
            instructions: "You are speaking aloud.",
            maxTokens: 1024)
        #expect(settings.instructions == "You are speaking aloud.")
    }

    @Test("nil on both sides means NO system message, as before 4v")
    func nilOnBothSidesIsNoSystemMessage() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(), instructions: nil, maxTokens: 1024)
        #expect(settings.instructions == nil)
    }

    // MARK: - AC-233: the budget

    @Test("per-call maxTokens replaces the source's own")
    func perCallBudgetWins() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(maxTokens: 3), instructions: nil, maxTokens: 1024)
        #expect(settings.maxTokens == 3)
    }

    @Test("nil maxTokens keeps the source's default — 1024 since F-6 = A")
    func nilBudgetKeepsTheDefault() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(), instructions: nil, maxTokens: 1024)
        #expect(settings.maxTokens == 1024)
    }

    // MARK: - AC-234: sampling

    @Test("temperature and seed travel; nil leaves the vendor's default untouched")
    func samplingTravels() {
        let given = MLXGenerationSettings(
            options: GenerationOptions(temperature: 0.25, seed: 7), instructions: nil, maxTokens: 8)
        #expect(given.temperature == 0.25)
        #expect(given.seed == 7)

        let left = MLXGenerationSettings(options: GenerationOptions(), instructions: nil, maxTokens: 8)
        #expect(left.temperature == nil, "nil is 'the vendor's own', never a number we invented")
        #expect(left.seed == nil)
    }

    @Test("the whole resolution is one Equatable value — the door hands it on, whole")
    func resolutionIsOneValue() {
        let options = GenerationOptions(instructions: "JSON only", maxTokens: 512, temperature: 0, seed: 1)
        let resolved = MLXGenerationSettings(options: options, instructions: "spoken", maxTokens: 1024)
        #expect(resolved == MLXGenerationSettings(
            instructions: "JSON only", maxTokens: 512, temperature: 0, seed: 1))
    }
}

/// AC-235: the vendor's stop reason, mapped by a pure function the live
/// path calls on the `.info` event it used to drop. `.cancelled` maps to
/// NOTHING — a cancelled run ends its stream with no terminal, which is
/// the seam's cancel contract, so there is no `StopReason` to say.
@Suite("AC-235 · the vendor's stop reason maps to the seam's StopReason")
struct MLXStopReasonMappingTests {

    @Test(".stop is .complete — the model ended its own turn")
    func stopIsComplete() {
        #expect(StopReason(vendor: .stop) == .complete)
    }

    @Test(".length is .tokenBudget — the cap cut it")
    func lengthIsTokenBudget() {
        #expect(StopReason(vendor: .length) == .tokenBudget)
    }

    @Test(".cancelled is nil — a cancelled run has no terminal to report")
    func cancelledIsNothing() {
        #expect(StopReason(vendor: .cancelled) == nil)
    }
}

/// AC-236 (the MLX half): the prompt is measured against the model's
/// window BEFORE generation, because the vendor does not throw for it —
/// it generates past the window and returns nonsense. The rule is pure,
/// and the window number is read from the weights' own `config.json`.
@Suite("AC-236 · a prompt longer than the window is refused before generation")
struct MLXPromptFitTests {

    @Test("a prompt that leaves room for one reply token fits")
    func fits() {
        #expect(PromptFit.refusal(promptTokens: 100, window: 4096) == nil)
        #expect(PromptFit.refusal(promptTokens: 4095, window: 4096) == nil,
                "the last position is the first reply token's")
    }

    @Test("a prompt that fills or exceeds the window is refused — nothing could be said")
    func refused() {
        #expect(PromptFit.refusal(promptTokens: 4096, window: 4096) == .contextWindowExceeded,
                "a full window leaves no position for a reply token")
        #expect(PromptFit.refusal(promptTokens: 5000, window: 4096) == .contextWindowExceeded)
    }

    @Test("no window number means no refusal — the library does not refuse on a number it lacks")
    func unknownWindowNeverRefuses() {
        #expect(PromptFit.refusal(promptTokens: 1_000_000, window: nil) == nil)
    }

    @Test("the window is read from config.json's max_position_embeddings, and absent is nil")
    func windowIsReadFromTheWeightsConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = directory.appending(path: "config.json")
        try Data(#"{"model_type": "qwen3", "max_position_embeddings": 40960}"#.utf8).write(to: config)
        #expect(try ContextWindow.read(fromConfigAt: config) == 40960)

        try Data(#"{"model_type": "qwen3"}"#.utf8).write(to: config)
        #expect(try ContextWindow.read(fromConfigAt: config) == nil,
                "a config that does not say has no number — nil, never a guess")
    }
}
