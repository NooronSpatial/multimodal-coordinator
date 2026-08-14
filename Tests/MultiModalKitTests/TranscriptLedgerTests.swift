import MultiModalKit
import Testing

/// RED SUITE for the ledger (SPEC AC-85/AC-86, D-040) — the pure half of
/// milestone 4c. No clock, no actor, no coordinator: every rule here is
/// proven by arithmetic, not raced for. The coordinator's own suite then
/// only has to prove the WIRING.
@Suite(.timeLimit(.minutes(1))) struct TranscriptLedgerTests {

    // MARK: - the byte-for-byte claim (D-040 F-5's promise)

    @Test func oneFinalIsExactlyItsOwnText() {
        // The claim that made "no flag" defensible: with a single final,
        // the whole thought IS that final's text — today's behaviour,
        // unchanged, for the common path.
        var ledger = TranscriptLedger()
        ledger.record("Do you think should I put my jacket?", utterance: 0)
        #expect(ledger.text == "Do you think should I put my jacket?")
        #expect(ledger.count == 1)
        #expect(!ledger.isEmpty)
    }

    // MARK: - AC-85: order, identity, dedup

    @Test func piecesJoinInSpokenOrder() {
        // The field scenario, in miniature.
        var ledger = TranscriptLedger()
        ledger.record("Do you hear me well?", utterance: 5)
        ledger.record("Can you understand what I'm telling you?", utterance: 6)
        ledger.record("should I take a jacket?", utterance: 7)
        #expect(ledger.text ==
            "Do you hear me well? Can you understand what I'm telling you? should I take a jacket?")
    }

    @Test func outOfOrderArrivalStillReadsInSpokenOrder() {
        // D-024's settling path can deliver an EARLIER utterance's final
        // after a later one. Identity is the sort key, so arrival order
        // cannot scramble the thought.
        var ledger = TranscriptLedger()
        ledger.record("third", utterance: 9)
        ledger.record("first", utterance: 3)
        ledger.record("second", utterance: 7)
        #expect(ledger.text == "first second third")
    }

    @Test func oneUtteranceContributesOnce() {
        // Two distinct pieces of speech cannot share an identity, so a
        // repeat is a repeat — never a second sentence.
        var ledger = TranscriptLedger()
        ledger.record("hello my friend", utterance: 4)
        ledger.record("hello my friend", utterance: 4)
        #expect(ledger.count == 1)
        #expect(ledger.text == "hello my friend")
    }

    @Test func aRepeatedIdentityDoesNotReorderTheThought() {
        // Re-recording an old identity must not move it to the end.
        var ledger = TranscriptLedger()
        ledger.record("first", utterance: 1)
        ledger.record("second", utterance: 2)
        ledger.record("first", utterance: 1)
        #expect(ledger.text == "first second")
    }

    // MARK: - AC-86: membership, exactly

    @Test func whitespaceIsNotSpeech() {
        // §46a finding 1: empty decodes are the field's most common
        // event. They are silence, and silence contributes nothing.
        var ledger = TranscriptLedger()
        ledger.record("", utterance: 0)
        ledger.record("   ", utterance: 1)
        ledger.record("\n\t ", utterance: 2)
        #expect(ledger.isEmpty)
        #expect(ledger.count == 0)
        #expect(ledger.text == "")
    }

    @Test func textIsTrimmedAtTheEdgesAndJoinedBySingleSpaces() {
        // The join is the library's one formatting decision (F-1 = A, and
        // D-027's objection to it is on the record). Pinned exactly.
        var ledger = TranscriptLedger()
        ledger.record("  padded left", utterance: 0)
        ledger.record("padded right   ", utterance: 1)
        #expect(ledger.text == "padded left padded right")
    }

    // MARK: - AC-85: the bound (D-040 F-4)

    @Test func theBoundDropsTheOldestAndKeepsSpokenOrder() {
        var ledger = TranscriptLedger(maxPieces: 3)
        ledger.record("one", utterance: 1)
        ledger.record("two", utterance: 2)
        ledger.record("three", utterance: 3)
        ledger.record("four", utterance: 4)
        #expect(ledger.count == 3)
        #expect(ledger.text == "two three four", "the OLDEST must go — the newest words matter most")
    }

    @Test func theBoundCountsPiecesNotRecords() {
        // A repeat is not new speech, so it must not push anything out.
        var ledger = TranscriptLedger(maxPieces: 2)
        ledger.record("one", utterance: 1)
        ledger.record("two", utterance: 2)
        ledger.record("one", utterance: 1)
        #expect(ledger.text == "one two")
    }

    @Test func aLateOldPieceCannotEvictANewerOneItPredates() {
        // An out-of-order arrival at a full ledger: utterance 1 arrives
        // last but is the OLDEST speech, so it is the piece that loses.
        var ledger = TranscriptLedger(maxPieces: 2)
        ledger.record("two", utterance: 2)
        ledger.record("three", utterance: 3)
        ledger.record("one", utterance: 1)
        #expect(ledger.text == "two three", "dropping oldest must mean oldest SPEECH, not oldest arrival")
    }

    // MARK: - AC-89: forgetting is deliberate

    @Test func clearForgetsEverything() {
        var ledger = TranscriptLedger()
        ledger.record("answered already", utterance: 0)
        ledger.clear()
        #expect(ledger.isEmpty)
        #expect(ledger.text == "")
        // …and the next thought starts clean, not renumbered.
        ledger.record("a new thought", utterance: 1)
        #expect(ledger.text == "a new thought")
    }
}
