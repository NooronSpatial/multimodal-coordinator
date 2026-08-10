import Testing
import MultiModalKitTesting

/// The ruler must be straight before anything is measured with it (AC-42).
@Suite(.timeLimit(.minutes(1)))
struct WordErrorRateTests {
    @Test("identical text scores zero")
    func identicalTextScoresZero() {
        let score = WordErrorRate.score(reference: "the ring may drop", hypothesis: "the ring may drop")
        #expect(score.wer == 0)
    }

    @Test("case and punctuation do not count")
    func normalizationIgnoresCaseAndPunctuation() {
        let score = WordErrorRate.score(reference: "The ring, may drop!", hypothesis: "the ring may drop")
        #expect(score.wer == 0)
    }

    @Test("one substitution in four words is 0.25 exactly")
    func oneSubstitutionScoresExactly() {
        let score = WordErrorRate.score(reference: "the ring may drop", hypothesis: "the ring may lie")
        #expect(score.substitutions == 1)
        #expect(score.wer == 0.25)
    }

    @Test("a missing word is a deletion; an extra word is an insertion")
    func deletionsAndInsertionsAreCounted() {
        let missing = WordErrorRate.score(reference: "the ring may drop", hypothesis: "the ring drop")
        #expect(missing.deletions == 1 && missing.wer == 0.25)

        let extra = WordErrorRate.score(reference: "the ring may drop", hypothesis: "the big ring may drop")
        #expect(extra.insertions == 1 && extra.wer == 0.25)
    }

    @Test("an empty hypothesis deletes every reference word")
    func emptyHypothesisDeletesEverything() {
        let score = WordErrorRate.score(reference: "the ring may drop", hypothesis: "")
        #expect(score.deletions == 4)
        #expect(score.wer == 1.0)
    }
}

extension WordErrorRateTests {
    @Test("digits are spelled out: 20 equals twenty")
    func digitsAreSpelledOut() {
        let score = WordErrorRate.score(reference: "chunks of twenty milliseconds",
                                        hypothesis: "chunks of 20 milliseconds")
        #expect(score.wer == 0)
    }
}
