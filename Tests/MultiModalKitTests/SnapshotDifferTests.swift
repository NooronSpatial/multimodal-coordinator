import MultiModalKit
import Testing

/// The tripwire's own proofs (SPEC §71, D-058). Pure — no model, no
/// clock, no gate. The measured stream (INSTRUMENTS §22) is the happy
/// path; everything a real device has NOT been seen to do is exercised
/// here, because here is the only place it can be produced on command.
@Suite struct SnapshotDifferTests {

    @Test("cumulative snapshots become exactly their new suffixes")
    func cumulativeBecomesSuffixes() throws {
        var differ = SnapshotDiffer()
        #expect(try differ.advance(to: "The") == "The")
        #expect(try differ.advance(to: "The capital") == " capital")
        #expect(try differ.advance(to: "The capital of France.") == " of France.")
        #expect(differ.emitted == "The capital of France.")
    }

    @Test("an unchanged snapshot is nothing to say, not a violation")
    func unchangedSnapshotIsEmpty() throws {
        var differ = SnapshotDiffer()
        _ = try differ.advance(to: "Same")
        #expect(try differ.advance(to: "Same") == "")
        #expect(differ.emitted == "Same")
    }

    @Test("the first snapshot is emitted whole, even when empty")
    func firstSnapshot() throws {
        var differ = SnapshotDiffer()
        #expect(try differ.advance(to: "") == "")
        #expect(try differ.advance(to: "Hello") == "Hello")
    }

    @Test("a REWRITE of emitted text throws, carrying both sides")
    func rewriteThrows() throws {
        var differ = SnapshotDiffer()
        _ = try differ.advance(to: "The answer is yes")
        #expect(throws: SnapshotRevision(emitted: "The answer is yes",
                                         snapshot: "The answer is no")) {
            _ = try differ.advance(to: "The answer is no")
        }
    }

    @Test("a SHRUNKEN snapshot throws — shorter cannot extend")
    func shrinkThrows() throws {
        var differ = SnapshotDiffer()
        _ = try differ.advance(to: "One. Two.")
        #expect(throws: SnapshotRevision.self) {
            _ = try differ.advance(to: "One.")
        }
    }

    @Test("after a violation the differ vouches for nothing new")
    func violationLeavesEmittedIntact() throws {
        var differ = SnapshotDiffer()
        _ = try differ.advance(to: "Spoken already")
        _ = try? differ.advance(to: "Rewritten")
        #expect(differ.emitted == "Spoken already",
                "the record of what may be in the room must survive the tripwire")
    }

    /// The probe's grapheme question, produced on command: a base letter
    /// is emitted, then the next snapshot completes it with a COMBINING
    /// mark. At the byte level that extends; at the character level —
    /// the level a mouth speaks at — "cafe" is not a prefix of "café",
    /// so the diff cannot cut a true suffix and must refuse.
    @Test("a combining mark landing on spoken text fires the tripwire")
    func graphemeSplitFires() throws {
        var differ = SnapshotDiffer()
        _ = try differ.advance(to: "cafe")
        #expect(throws: SnapshotRevision.self) {
            _ = try differ.advance(to: "cafe\u{0301} au lait")   // e + ◌́
        }
    }

    @Test("multi-byte text diffs at character boundaries, not bytes")
    func multibyteSuffixes() throws {
        var differ = SnapshotDiffer()
        #expect(try differ.advance(to: "Voilà") == "Voilà")
        #expect(try differ.advance(to: "Voilà — déjà vu 🎉") == " — déjà vu 🎉")
    }
}
