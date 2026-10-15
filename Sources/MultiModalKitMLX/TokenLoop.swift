import MLXLMCommon
import MultiModalKit

/// What `TokenLoop` needs from a token iterator: the vendor's `TokenIterator`,
/// or a scripted one in the tests.
protocol LoopTokens {
    /// The next token — for the real iterator, one step of GPU work. Nil when
    /// the iterator is done (the budget reached, or nothing more).
    mutating func next() -> Int?
    /// Drops the stop token from the iterator's state, as the vendor's loop does.
    mutating func discardGeneratedToken()
    var tokenCount: Int { get }
    var maxTokens: Int? { get }
}

extension TokenIterator: LoopTokens {}

/// OUR OWN TOKEN LOOP (5d piece 5, D-149; AC-382, AC-383). The vendor's loop
/// runs in its own task and never waits for its reader, so it cannot let the
/// voice go first; this one does the same work and waits for the floor
/// between tokens.
enum TokenLoop {
    /// Runs `tokens` to its end and says why it ended.
    /// - Parameters:
    ///   - isStop: the vendor's stop test (the unknown token and every EOS).
    ///   - floor: waited for BETWEEN tokens, never inside one.
    ///   - each: every token that is not a stop, in order, once.
    static func run<Tokens: LoopTokens>(
        _ tokens: inout Tokens, isStop: (Int) -> Bool, floor: VoiceFloor?,
        each: (Int) -> Void
    ) async -> GenerateStopReason {
        .cancelled
    }
}
