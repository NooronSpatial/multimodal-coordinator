/// TURNS CUMULATIVE SNAPSHOTS INTO SPEAKABLE SUFFIXES — and checks, every
/// time, the one property that makes that safe (SPEC §71, D-058).
///
/// Apple's language model does not stream tokens. It streams SNAPSHOTS —
/// the whole reply so far, again and again: `"The"`, `"The capital"`,
/// `"The capital of France."`. Downstream, `SpeechPhraser` concatenates
/// verbatim, so feeding snapshots through would speak "The The capital
/// The capital of France." The adapter must emit only what is NEW.
///
/// The diff is correct only while every snapshot EXTENDS the one before
/// it. That property was MEASURED before it was trusted — 23 snapshot
/// pairs on an iPhone, all strictly extending (INSTRUMENTS §22) — and it
/// is still checked on every call, because one run is evidence, not a
/// law, and the same afternoon's Simulator vouched for a model it could
/// not produce. A platform that can lie about availability earns a check
/// on its stream shape.
///
/// The failure the check prevents is the worst this pipeline can make:
/// words already SPOKEN into the room that the model then rewrote —
/// audible garbage with no alarm anywhere. Audio cannot be unsaid, so a
/// revision here is a thrown `SnapshotRevision`, and the caller turns it
/// into one honest `.failed` instead of a wrong sentence.
///
/// Pure and clockless, the `SpeechPhraser` shape: no time source, no
/// model, no threads — which is what lets the tripwire law be proven on
/// any machine, with no weights installed.
public struct SnapshotDiffer: Sendable {

    /// Everything vouched for so far — the text the caller may already
    /// have handed to a mouth.
    public private(set) var emitted = ""

    public init() {}

    /// Accepts the next cumulative snapshot; returns only what is NEW.
    ///
    /// An unchanged snapshot returns the empty string — no growth is not
    /// a violation, it is just nothing to say yet.
    ///
    /// - Throws: `SnapshotRevision` when `snapshot` does not extend what
    ///   was already emitted. That includes a snapshot that SHRANK, one
    ///   that rewrote earlier text, and one that extends at the byte
    ///   level but lands mid-grapheme (a combining mark arriving after
    ///   its base was already spoken) — `hasPrefix` compares characters,
    ///   which is the level a mouth speaks at.
    public mutating func advance(to snapshot: String) throws -> String {
        guard snapshot.hasPrefix(emitted) else {
            throw SnapshotRevision(emitted: emitted, snapshot: snapshot)
        }
        // The cut is in CHARACTERS, which is safe exactly because the
        // prefix held at character level one line above.
        let suffix = String(snapshot.dropFirst(emitted.count))
        emitted = snapshot
        return suffix
    }
}

/// THE TRIPWIRE FIRED: the model revised text that may already be in the
/// room. Carries both sides so the failure report can show, not describe.
public struct SnapshotRevision: Error, Equatable, Sendable {
    /// What had been emitted — and possibly spoken — before the revision.
    public let emitted: String
    /// The snapshot that failed to extend it.
    public let snapshot: String

    public init(emitted: String, snapshot: String) {
        self.emitted = emitted
        self.snapshot = snapshot
    }
}
