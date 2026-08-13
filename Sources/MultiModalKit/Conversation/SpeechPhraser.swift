/// The mouth's private assembler (SPEC AC-79, D-037 F-1).
///
/// Tokens arrive at ANY granularity — whole words from a scripted
/// generator, subword fragments ("con", "curr", "ency") with punctuation
/// glued on (". The") from a future one — and phrases leave, ready to be
/// spoken. The seam law is untouched: the coordinator forwards every
/// token unbuffered; the buffering that must exist somewhere lives HERE,
/// below the seam, so no producer and no coordinator ever knows.
///
/// Deliberately pure: no clock, no tasks. Text in, phrases out.
/// Concatenation is VERBATIM — tokens carry their own spacing (the way
/// real generators emit them); the phraser never invents a space.
///
/// RED skeleton: the shape without the judgment. Every rule below is a
/// failing test until GREEN wires it.
public struct SpeechPhraser: Sendable {
    public struct Config: Sendable {
        /// A phrase is cut here even without punctuation, at the last
        /// whitespace before the limit (or hard, if one unbroken run).
        public var maxPhraseCharacters: Int

        public init(maxPhraseCharacters: Int = 120) {
            self.maxPhraseCharacters = maxPhraseCharacters
        }
    }

    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one token; receive every phrase it completed (usually none).
    public mutating func feed(_ token: String) -> [String] {
        []
    }

    /// No more tokens are coming: the remainder, if any words are in it.
    public mutating func flush() -> String? {
        nil
    }
}
