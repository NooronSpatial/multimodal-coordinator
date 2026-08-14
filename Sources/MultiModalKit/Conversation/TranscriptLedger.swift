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

    public init(maxPieces: Int = 16) {
        self.maxPieces = maxPieces
    }

    /// Records what one utterance said. Whitespace-only text is not
    /// speech and is never recorded; a repeated identity records once.
    public mutating func record(_ text: String, utterance: Int) {
    }

    /// The whole thought, in spoken order — what the generator receives
    /// (F-1 = A: the seam stays a String).
    public var text: String { "" }

    /// True when nothing worth saying has been recorded.
    public var isEmpty: Bool { true }

    /// How many pieces are held — the bound's observable side.
    public var count: Int { 0 }

    /// Forgets everything. Called when the thought was ANSWERED
    /// (D-040 F-2: on `turnCompleted`, and only there).
    public mutating func clear() {
    }
}
