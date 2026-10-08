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
        /// GROWING PHRASES (5d piece 2; SPEC §235/2, F-34 A, AC-350): the
        /// caps of a reply's FIRST phrases, in order — `[20, 40]` cuts the
        /// first at 20 characters and the second at 40, then every phrase
        /// at `maxPhraseCharacters`. Each is cut at the last whitespace
        /// before its cap, and a clause mark that comes first still wins.
        /// Empty: every phrase as before.
        public var openingCaps: [Int]

        public init(maxPhraseCharacters: Int = 120, openingCaps: [Int] = []) {
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
            // The same refusal, for the same reason: a cap below one could
            // not advance the cut.
            precondition(openingCaps.allSatisfy { $0 >= 1 },
                         "SpeechPhraser needs room for at least one character in every opening cap")
            self.openingCaps = openingCaps
        }
    }

    private let config: Config
    /// Text that has arrived but not yet left as a phrase. Verbatim.
    private var buffer = ""
    /// Phrases with something to say that have left, for the opening caps.
    private var emitted = 0

    /// The clause marks a phrase is cut at — one set, read by the cut and
    /// by `PhraseQuiet.closingMark(of:)`, so the two cannot disagree.
    /// ASCII, and the Arabic comma `،`, question mark `؟` and semicolon `؛`
    /// (4u, AC-214) — the same marks in a different script.
    static let clauseMarks: Set<Character> = [".", ",", ":", ";", "?", "!", "،", "؟", "؛"]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one token; receive every phrase it completed (usually none).
    public mutating func feed(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }
        buffer += token

        var phrases: [String] = []
        // ONE RULE, DECIDED BY POSITION (5d piece 2): a phrase ends at
        // whichever comes FIRST in the text — a clause mark within its cap,
        // or the cap itself. Deciding by position is what makes one burst
        // and a stream of single characters cut a reply the same way: the
        // first version ran the clause rule over the whole buffer before the
        // cap, and a burst's first phrase ran past both (found by the
        // bakeoff, which feeds a reply in one `feed`).
        while let cut = nextCut() {
            leave(at: cut, into: &phrases)
        }
        // THE LIVENESS INVARIANT: never emit a phrase with nothing to say.
        // Downstream every phrase becomes one utterance the mouth must
        // account for before the turn completes, and a platform is free to
        // stay silent about an unspeakable one — which would strand the
        // turn forever. Only the max-length cut can produce such a piece
        // (a long whitespace run); dropping it costs nothing but spaces.
        return phrases.filter { $0.contains(where: { !$0.isWhitespace }) }
    }

    /// One phrase leaves at `cut`; a phrase with something to say counts
    /// toward the opening caps.
    private mutating func leave(at cut: String.Index, into phrases: inout [String]) {
        let phrase = String(buffer[..<cut])
        buffer = String(buffer[cut...])
        phrases.append(phrase)
        if phrase.contains(where: { !$0.isWhitespace }) { emitted += 1 }
    }

    /// No more tokens are coming: the remainder, if any words are in it.
    public mutating func flush() -> String? {
        defer { buffer = "" }
        guard buffer.contains(where: { !$0.isWhitespace }) else { return nil }
        return buffer
    }

    /// Where the oldest phrase ends, if the text so far already says.
    ///
    /// Rule 1: a clause mark followed by whitespace, within the cap ("3.14"
    /// survives: its mark is followed by a digit, not space). Rule 2: past
    /// the cap, the last whitespace before it — no word is ever torn. One
    /// unbroken run is cut hard at the LIMIT: it cannot wait forever, and a
    /// cut mid-run beats no speech at all. `max(1, …)` is belt to the
    /// precondition's braces: the loop must be unable to spin even if a
    /// limit of zero ever reaches it.
    ///
    /// GROWING PHRASES (5d piece 2, F-34 A): while a reply's first phrases
    /// are being cut, the cap is the opening one — and a single word longer
    /// than it is NOT torn but left whole, cut at the first whitespace after
    /// it (the limit still binds).
    private func nextCut() -> String.Index? {
        let limitCap = max(1, config.maxPhraseCharacters)
        let opening = emitted < config.openingCaps.count
        let cap = opening ? min(max(1, config.openingCaps[emitted]), limitCap) : limitCap
        if let mark = boundary(within: cap) { return mark }
        guard buffer.count > cap else { return nil }
        let limit = buffer.index(buffer.startIndex, offsetBy: cap)
        if let space = buffer[..<limit].lastIndex(where: \.isWhitespace), space != buffer.startIndex {
            return space
        }
        if opening {
            if let space = buffer[limit...].firstIndex(where: \.isWhitespace),
               buffer.distance(from: buffer.startIndex, to: space) <= limitCap {
                return space                                   // the long word, whole
            }
            if buffer.count <= limitCap { return nil }         // the word goes on: wait for its end
        }
        return buffer.index(buffer.startIndex, offsetBy: limitCap)
    }

    /// The index just past the first clause mark whose neighbor is
    /// whitespace — when the phrase it closes is at most `cap` characters.
    private func boundary(within cap: Int) -> String.Index? {
        var cursor = buffer.startIndex
        var length = 0
        while cursor < buffer.endIndex, length < cap {
            length += 1
            if Self.clauseMarks.contains(buffer[cursor]) {
                let next = buffer.index(after: cursor)
                if next < buffer.endIndex, buffer[next].isWhitespace {
                    return next
                }
            }
            cursor = buffer.index(after: cursor)
        }
        return nil
    }
}
