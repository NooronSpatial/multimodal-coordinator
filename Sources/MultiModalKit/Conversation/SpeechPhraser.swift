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
    /// Text that has arrived but not yet left as a phrase. Verbatim.
    private var buffer = ""

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one token; receive every phrase it completed (usually none).
    public mutating func feed(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }
        buffer += token

        var phrases: [String] = []
        // Rule 1: a clause mark followed by whitespace ends a phrase.
        // ("3.14" survives: its mark is followed by a digit, not space.)
        while let cut = boundary() {
            phrases.append(String(buffer[..<cut]))
            buffer = String(buffer[cut...])
        }
        // Rule 2: past the limit, cut at the last whitespace before it —
        // no word is ever torn. One unbroken run is cut hard: it cannot
        // wait forever, and a cut mid-run beats no speech at all.
        while buffer.count > config.maxPhraseCharacters {
            let limit = buffer.index(buffer.startIndex,
                                     offsetBy: config.maxPhraseCharacters)
            let head = buffer[..<limit]
            if let space = head.lastIndex(where: \.isWhitespace),
                space != buffer.startIndex {
                phrases.append(String(buffer[..<space]))
                buffer = String(buffer[space...])
            } else {
                phrases.append(String(head))
                buffer = String(buffer[limit...])
            }
        }
        // THE LIVENESS INVARIANT: never emit a phrase with nothing to say.
        // Downstream every phrase becomes one utterance the mouth must
        // account for before the turn completes, and a platform is free to
        // stay silent about an unspeakable one — which would strand the
        // turn forever. Only the max-length cut can produce such a piece
        // (a long whitespace run); dropping it costs nothing but spaces.
        return phrases.filter { $0.contains(where: { !$0.isWhitespace }) }
    }

    /// No more tokens are coming: the remainder, if any words are in it.
    public mutating func flush() -> String? {
        defer { buffer = "" }
        guard buffer.contains(where: { !$0.isWhitespace }) else { return nil }
        return buffer
    }

    /// The index just past the first clause mark whose neighbor is
    /// whitespace — the cut point of the oldest completed phrase.
    private func boundary() -> String.Index? {
        var i = buffer.startIndex
        while i < buffer.endIndex {
            if ".,:;?!".contains(buffer[i]) {
                let next = buffer.index(after: i)
                if next < buffer.endIndex, buffer[next].isWhitespace {
                    return next
                }
            }
            i = buffer.index(after: i)
        }
        return nil
    }
}
