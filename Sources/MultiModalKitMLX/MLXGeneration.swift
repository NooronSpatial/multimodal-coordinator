import Foundation
import MLXLMCommon
import MultiModalKit

// THE DECISIONS THE LOCAL MIND MAKES BEFORE IT TOUCHES THE VENDOR
// (4v, SPEC §175/1–3, D-103).
//
// Everything here is a pure function or a plain value: options in,
// settings out; a vendor reason in, a seam reason out; a token count in,
// a refusal or nil out. None of it needs weights, a GPU or a metallib,
// which is the whole reason it lives apart from `LocalMind.swift` — the
// live path there is proven by gated tests that need all three, and the
// RULES it applies are proven here on every machine (AC-232..236).

// MARK: - what one generation is asked to do (AC-232, AC-233, AC-234)

/// The caller's per-call `GenerationOptions`, resolved against the
/// source's own settings. `nil` on an option means "the source's own"
/// (F-1 = A): the instructions and the budget fall back to what the
/// generator was built with; the sampling levers fall back to the
/// VENDOR's defaults by staying `nil`, so this type never invents a
/// temperature the caller did not ask for.
struct MLXGenerationSettings: Sendable, Equatable {
    /// The `.system` message, or none. `options.instructions ??
    /// self.instructions` (AC-232); `nil` on both sides is no system
    /// message at all — exactly today's behaviour for the voice path.
    var instructions: String?
    /// `options.maxTokens ?? self.maxTokens` (AC-233); the initializer's
    /// default is 1024 since F-6 = A.
    var maxTokens: Int
    /// `nil` leaves the vendor's default (0.6) untouched. `0` is the
    /// greedy path — the vendor's `sampler()` returns its arg-max sampler
    /// for exactly `temperature == 0`, so a caller asking for
    /// determinism gets it without a second lever (AC-234).
    var temperature: Float?
    /// `nil` leaves the vendor's randomness alone (AC-234).
    var seed: UInt64?

    init(instructions: String?, maxTokens: Int, temperature: Float?, seed: UInt64?) {
        self.instructions = instructions
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
    }

    /// The resolution rule, in one place.
    init(options: GenerationOptions, instructions: String?, maxTokens: Int) {
        self.init(instructions: options.instructions ?? instructions,
                  maxTokens: options.maxTokens ?? maxTokens,
                  temperature: options.temperature,
                  seed: options.seed)
    }
}

extension GenerateParameters {
    /// The vendor's parameters from the resolved settings: CONSTRUCTED
    /// WITH THE VENDOR'S DEFAULTS, then only what was given is assigned —
    /// so a `nil` temperature is the vendor's 0.6 and stays 0.6 when the
    /// vendor changes its mind, not a copy of that number frozen here.
    ///
    /// THE SEED IS PER GENERATION, not process-global. The spec (§174)
    /// was drafted on the belief that `MLXRandom.seed` was the only way
    /// in; the vendor resolved into this build takes `seed` on the
    /// parameters and builds a private `RandomState(seed:)` for the
    /// sampler of THAT generation (`Evaluate.swift`: `TopPSampler` /
    /// `CategoricalSampler`), so two seeded generations cannot disturb
    /// each other and nothing global is written. Checked, not assumed —
    /// the live determinism probe (AC-234) is the proof it reaches the
    /// sampler.
    init(_ settings: MLXGenerationSettings) {
        self.init()
        maxTokens = settings.maxTokens
        if let temperature = settings.temperature { self.temperature = temperature }
        if let seed = settings.seed { self.seed = seed }
    }
}

// MARK: - why the vendor stopped (AC-235)

extension StopReason {
    /// The vendor's `.info` event, which the source used to DROP, mapped
    /// to the seam's word. `.stop` is the model ending its own turn;
    /// `.length` is the cap. `.cancelled` is `nil` on purpose: a
    /// cancelled run ends its stream with NO terminal — that is the
    /// seam's cancel contract — so there is no reason to report, and
    /// yielding one would be a terminal after a cancel, the exact thing
    /// promise 3 forbids.
    init?(vendor: GenerateStopReason) {
        switch vendor {
        case .stop: self = .complete
        case .length: self = .tokenBudget
        case .cancelled: return nil
        }
    }
}

// MARK: - does the prompt fit (AC-236)

/// The window check the vendor does not do: `generateTokens` runs past
/// `max_position_embeddings` without throwing, and the model answers
/// with noise. So the prepared prompt is COUNTED before generation and
/// refused as `.contextWindowExceeded` — a case a caller can count,
/// which is what F-3 = A is for.
enum PromptFit {
    /// `nil` when the prompt fits, `.contextWindowExceeded` when it does
    /// not. The prompt must leave room for at least ONE reply token — a
    /// prompt that fills every position is refused too, because the
    /// vendor would still "generate" and nothing it said could be
    /// trusted. An unknown window (`nil`) never refuses: the library
    /// does not refuse on a number it does not have (D-092's lesson,
    /// the same one `MindReadiness` applies to memory).
    static func refusal(promptTokens: Int, window: Int?) -> ReplyFailure? {
        guard let window, promptTokens >= window else { return nil }
        return .contextWindowExceeded
    }
}

/// Where the window number comes from: the weights' own `config.json`.
/// The vendor's LLM configurations do not surface it (only its VLM ones
/// decode `max_position_embeddings`), so it is read here, once, and
/// cached by the model that owns the directory.
enum ContextWindow {
    /// `max_position_embeddings`, or `nil` when the config does not say.
    /// Throws only when the file cannot be read or is not JSON — a
    /// config that is silent about its window is not an error, it is a
    /// model this check cannot help.
    static func read(fromConfigAt url: URL) throws -> Int? {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { return nil }
        return object["max_position_embeddings"] as? Int
    }
}
