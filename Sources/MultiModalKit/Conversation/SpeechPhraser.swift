import Foundation
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

    /// IS THERE ANYTHING WORTH SAYING? (AC-106.)
    ///
    /// Found by a test that hung. A phrase of pure whitespace or pure
    /// punctuation gives an autoregressive voice nothing to end on, so
    /// the model decodes toward its own step cap — 245 steps in TTSKit,
    /// about **19.6 seconds of audio for a phrase containing nothing**.
    /// Sometimes it stopped early instead, which is worse: it made the
    /// failure a coin flip.
    ///
    /// The turn loop cannot afford that. It waits inline for a mouth to
    /// report `finished`, so one stray whitespace phrase buys twenty
    /// seconds of dead air. So the mouths ask this first, and a phrase
    /// with nothing in it is completed rather than spoken.
    ///
    /// **Letters OR digits, in any script.** A rule that asked for A–Z
    /// would mute Arabic, Japanese and Russian — a far worse bug than
    /// the one it was written to fix — so the test is Unicode's own
    /// letter and number classes, not an alphabet.
    public static func hasSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
    }
    public struct Config: Sendable {
        /// A phrase is cut here even without punctuation, at the last
        /// whitespace before the limit (or hard, if one unbroken run).
        public var maxPhraseCharacters: Int

        public init(maxPhraseCharacters: Int = 120) {
            // A limit below one cannot be honoured: there would be no room
            // for a single character, the cut could not advance, and `feed`
            // would spin forever building empty phrases. Found by review
            // before any caller met it; refused loudly here rather than
            // clamped silently, because a caller asking for zero has a bug
            // of their own and deserves to hear about it. (This type and
            // its Config are public API — the seam invites other mouths.)
            precondition(maxPhraseCharacters >= 1,
                         "SpeechPhraser needs room for at least one character")
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
        // `max(1, …)` is belt to the precondition's braces: the loop must be
        // unable to spin even if a limit of zero ever reaches it.
        let cap = max(1, config.maxPhraseCharacters)
        while buffer.count > cap {
            let limit = buffer.index(buffer.startIndex, offsetBy: cap)
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
