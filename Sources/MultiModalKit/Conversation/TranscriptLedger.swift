/// What the speaker said, kept whole (SPEC AC-85/AC-86, D-040).
///
/// A turn used to answer its LAST accepted final and nothing else, so a
/// two-sentence question with a pause in it got an answer to sentence
/// two. The ledger holds the pieces of one thought and hands the
/// generator all of them.
///
/// The doctrine line it rests on (D-040): **user speech is EVIDENCE; a
/// turn's reply tokens are COMPUTATION.** The turn ticket exists to stop
/// cancelled computation from surfacing — words the speaker really said
/// do not stop being true when a ticket expires. So a final REFUSED at
/// the input door still contributes its words here, while opening no
/// turn, arming no gate and moving no ticket.
///
/// Deliberately pure: no clock, no actor, no tasks. Its whole suite runs
/// synchronously, which is why the hard rules below can be proven exactly
/// rather than raced for.
///
/// Order and identity come from ONE place: the utterance number the pump
/// assigns at birth (D-034). It is monotonic at the source, so it equals
/// spoken order by construction — unlike `AudioTime`, whose value on a
/// settled batch final is "frames fed to that run", not "when the words
/// happened". That also gives dedup for free: two distinct pieces of
/// speech cannot share an identity.
///
/// Public for the same reason `SpeechPhraser` is: the house tests the
/// real public surface, never a `@testable` back door.
///
/// RED skeleton: the shape without the judgment. Every rule is a failing
/// test until GREEN wires it.
public struct TranscriptLedger: Sendable, Equatable {
    /// The most pieces one thought may hold. Oldest is dropped past this
    /// (the D-012 house idiom). The bound is not decoration: without it,
    /// F-2's "a failed turn keeps its words" would let an oversized
    /// prompt fail, keep the words, and fail again — wedged forever
    /// (D-040 F-4). Counting PIECES is enough because the 30-second
    /// utterance ceiling (D-021) already bounds each one.
    public let maxPieces: Int

    /// Kept sorted by utterance identity — the thought in spoken order.
    /// An array, not a dictionary: it holds at most `maxPieces` entries,
    /// so a linear insert is cheaper than hashing, and "sorted" is then
    /// a fact of the storage rather than a step at every read.
    private var pieces: [(utterance: Int, text: String)] = []

    public init(maxPieces: Int = 16) {
        precondition(maxPieces > 0, "a ledger that can hold nothing is not a bound, it is a bug")
        self.maxPieces = maxPieces
    }

    /// Records what one utterance said. Whitespace-only text is not
    /// speech and is never recorded; a repeated identity records once.
    public mutating func record(_ text: String, utterance: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }          // silence is not speech

        // Identity is unique per utterance (D-034), so a match is a
        // REPEAT of the same speech — never a second sentence. First
        // text wins, and the piece keeps its place in the thought.
        guard !pieces.contains(where: { $0.utterance == utterance }) else { return }

        // Insert in identity order: arrival order may be scrambled by
        // D-024's settling path, spoken order never is.
        let slot = pieces.firstIndex { $0.utterance > utterance } ?? pieces.count
        pieces.insert((utterance, trimmed), at: slot)

        // Past the bound, the OLDEST SPEECH goes — which is index 0
        // precisely because the array is kept in spoken order. A late
        // old piece therefore evicts itself, never a newer one.
        if pieces.count > maxPieces { pieces.removeFirst(pieces.count - maxPieces) }
    }

    /// The whole thought, in spoken order — what the generator receives
    /// (F-1 = A: the seam stays a String).
    public var text: String {
        pieces.map(\.text).joined(separator: " ")
    }

    /// True when nothing worth saying has been recorded.
    public var isEmpty: Bool { pieces.isEmpty }

    /// How many pieces are held — the bound's observable side.
    public var count: Int { pieces.count }

    /// Forgets everything. Called when the thought was ANSWERED
    /// (D-040 F-2: on `turnCompleted`, and only there).
    public mutating func clear() {
        pieces.removeAll(keepingCapacity: true)
    }

    /// Value equality over the pieces — tuples are not `Equatable`, so
    /// the synthesised conformance cannot see them.
    public static func == (lhs: TranscriptLedger, rhs: TranscriptLedger) -> Bool {
        lhs.maxPieces == rhs.maxPieces
            && lhs.pieces.count == rhs.pieces.count
            && zip(lhs.pieces, rhs.pieces).allSatisfy { $0 == $1 }
    }
}
