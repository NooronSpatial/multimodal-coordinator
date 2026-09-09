import Foundation
import MLXLMCommon
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

/// AC-232 (the MLX half, the wiring the 4v review found untested): the
/// RESOLVED instruction has to become the real `.system` message. The
/// resolution struct above proves the RULE; nothing proved that its
/// answer reached the chat the model is handed, and the builder was
/// `private`, so no test could even look.
///
/// `Chat.Message` is the vendor's, and is neither `Equatable` nor
/// `Sendable` — so each message is read as the two fields that carry its
/// meaning, in order. No weights, no GPU: building a chat is arithmetic.
@Suite("AC-232 · the resolved instruction becomes the .system message")
struct MLXChatMessagesTests {

    /// "role: content", in birth order — what the model is actually told.
    private func rendered(_ messages: [Chat.Message]) -> [String] {
        messages.map { "\($0.role.rawValue): \($0.content)" }
    }

    @Test("the caller's per-call instruction is the system message — Aura's G1")
    func perCallInstructionBecomesTheSystemMessage() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(instructions: "Propose a session as JSON."),
            instructions: "You are speaking aloud.",
            maxTokens: 1024)
        let built = MLXTokenSource.messages(spoken: settings.instructions,
                                            asked: "plan my week", past: [])
        #expect(rendered(built) == ["system: Propose a session as JSON.",
                                    "user: plan my week"],
                "the per-call instruction replaces the source's own IN THE CHAT, not only in the struct")
    }

    @Test("nil per-call instructions leave the source's own as the system message")
    func theSourcesOwnInstructionSurvives() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(), instructions: "You are speaking aloud.", maxTokens: 1024)
        let built = MLXTokenSource.messages(spoken: settings.instructions,
                                            asked: "hello", past: [])
        #expect(rendered(built) == ["system: You are speaking aloud.", "user: hello"])
    }

    @Test("nil on both sides is NO system message at all — the voice path, unchanged")
    func noInstructionMeansNoSystemMessage() {
        let settings = MLXGenerationSettings(
            options: GenerationOptions(), instructions: nil, maxTokens: 1024)
        let built = MLXTokenSource.messages(spoken: settings.instructions,
                                            asked: "hello", past: [])
        #expect(rendered(built) == ["user: hello"], "an empty system message is not the same as none")
    }

    /// The rest of the builder, which was never read by a test either:
    /// the past arrives IN ROLES (4r, F-1 = B) and a barged reply keeps
    /// its ellipsis — punctuation, not English (F-2 = C).
    @Test("the past arrives in roles, and a barged reply ends in the ellipsis")
    func thePastArrivesInRoles() {
        let built = MLXTokenSource.messages(
            spoken: "be brief",
            asked: "and then?",
            past: [ConversationTurn(said: "hello", replied: "hi there"),
                   ConversationTurn(said: "tell me a story", replied: "once upon a time",
                                    interrupted: true)])
        #expect(rendered(built) == ["system: be brief",
                                    "user: hello",
                                    "assistant: hi there",
                                    "user: tell me a story",
                                    "assistant: once upon a time…",
                                    "user: and then?"])
    }
}

/// AC-233 / AC-234 (the vendor half, the mapping the 4v review found
/// untested): `GenerateParameters.init(_ settings:)` is the ONE place a
/// resolved setting becomes a vendor parameter, and CI — which has no
/// `MMK_MLX_MODEL` — never reached it, so the whole mapping rested on
/// the gated live probe.
///
/// Constructing `GenerateParameters` needs no weights, no GPU and no
/// metallib: it is a struct of numbers.
@Suite("AC-233/AC-234 · the resolved settings become the vendor's parameters")
struct MLXGenerateParametersTests {

    @Test("the budget reaches maxTokens, and nothing else is invented")
    func theBudgetReachesTheVendor() {
        let parameters = GenerateParameters(
            MLXGenerationSettings(instructions: nil, maxTokens: 3, temperature: nil, seed: nil))
        #expect(parameters.maxTokens == 3)
        #expect(parameters.temperature == GenerateParameters().temperature,
                "a nil temperature is the VENDOR's default, read from the vendor — never a copy frozen here")
        #expect(parameters.seed == nil, "no seed asked, no seed set")
    }

    @Test("temperature and seed reach the vendor when the caller gives them")
    func samplingReachesTheVendor() {
        let parameters = GenerateParameters(
            MLXGenerationSettings(instructions: nil, maxTokens: 1024, temperature: 0.25, seed: 7))
        #expect(parameters.temperature == 0.25, "binary-exact: 0.25 is exact in binary, 0.2 is not")
        #expect(parameters.seed == 7)
        #expect(parameters.maxTokens == 1024)
    }

    /// The greedy path AC-234 leans on: the vendor returns its arg-max
    /// sampler for EXACTLY `temperature == 0`, which is why a caller
    /// asking for determinism needs no second lever.
    @Test("temperature 0 travels as 0 — the greedy path, not a nil that becomes 0.6")
    func greedyTravelsAsZero() {
        let parameters = GenerateParameters(
            MLXGenerationSettings(instructions: nil, maxTokens: 24, temperature: 0, seed: nil))
        #expect(parameters.temperature == 0)
    }
}
