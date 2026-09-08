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

    // MARK: - Arabic (4u, AC-213, F-5 = B)

    /// The English normaliser scores Arabic as ALL WRONG in ways that have
    /// nothing to do with what was said: a diacritic is not a letter, so
    /// `isLetter` turns it into a space and breaks the word in two; the
    /// four alef forms are four different letters; taa marbuta and alef
    /// maqsura are spelled two ways by every writer alive. Whisper emits
    /// none of the diacritics and any of the spellings. Each rule below
    /// is one thing a native reader ignores and a byte comparison does not.
    @Test("Arabic: diacritics (tashkeel) do not count")
    func arabicDiacriticsDoNotCount() {
        let score = WordErrorRate.score(reference: "مرحبا بكم", hypothesis: "مَرْحَبًا بِكُمْ")
        #expect(score.wer == 0, "\(score)")
    }

    @Test("Arabic: the four alef forms are one letter")
    func arabicAlefFormsAreOneLetter() {
        #expect(WordErrorRate.score(reference: "أحمد إلى آخر", hypothesis: "احمد الى اخر").wer == 0)
    }

    @Test("Arabic: taa marbuta and alef maqsura fold to their common spellings")
    func arabicTaaMarbutaAndAlefMaqsuraFold() {
        #expect(WordErrorRate.score(reference: "العاصمة على", hypothesis: "العاصمه علي").wer == 0)
    }

    @Test("Arabic: tatweel (the stretching mark) is not a letter")
    func arabicTatweelIsRemoved() {
        #expect(WordErrorRate.score(reference: "الجزائر", hypothesis: "الـــجزائر").wer == 0)
    }

    @Test("Arabic: Arabic punctuation does not count")
    func arabicPunctuationDoesNotCount() {
        #expect(WordErrorRate.score(reference: "الأذن، والعقل، والفم؟", hypothesis: "الاذن والعقل والفم").wer == 0)
    }

    /// The ruler must still MEASURE: folding must not make different words
    /// the same word.
    @Test("Arabic: a real substitution still counts")
    func arabicSubstitutionStillCounts() {
        let score = WordErrorRate.score(reference: "عاصمة الجزائر", hypothesis: "عاصمة تونس")
        #expect(score.substitutions == 1 && score.wer == 0.5)
    }

    /// And the English ruler is untouched by the Arabic rules — the same
    /// four words the first test in this file has always used.
    @Test("English normalisation is unchanged by the Arabic rules")
    func englishIsUnchanged() {
        #expect(WordErrorRate.normalize("The ring, may drop!") == ["the", "ring", "may", "drop"])
        #expect(WordErrorRate.normalize("chunk 20 ms") == ["chunk", "twenty", "ms"])
    }
}
