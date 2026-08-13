import MultiModalKit
import Testing

/// RED SUITE for the phraser (SPEC AC-79, D-037 F-1) — the component that
/// makes ANY producer speakable: whole words today, subword fragments
/// tomorrow. Pure text in, phrases out; every rule exact.
@Suite(.timeLimit(.minutes(1))) struct SpeechPhraserTests {

    /// Feeds a script and collects everything the phraser emits, the
    /// flush included — the way a SynthesisRun will drive it.
    private func speak(_ tokens: [String], config: SpeechPhraser.Config = .init())
        -> [String]
    {
        var phraser = SpeechPhraser(config: config)
        var phrases: [String] = []
        for token in tokens {
            phrases.append(contentsOf: phraser.feed(token))
        }
        if let rest = phraser.flush() { phrases.append(rest) }
        return phrases
    }

    // MARK: - the two producers, one mouth (D-037 F-1)

    @Test func wordTokensSplitAtPunctuation() {
        // A scripted generator: words carrying their own spacing.
        let phrases = speak(["You", " said:", " the", " audio", " travels."])
        #expect(phrases == ["You said:", " the audio travels."])
    }

    @Test func subwordFragmentsAreJoinedVerbatim() {
        // The 4c future: an LLM emits pieces of one word. The phraser
        // must never pronounce them apart — and never invent a space.
        let phrases = speak(["con", "curr", "ency", " matters."])
        #expect(phrases == ["concurrency matters."])
    }

    @Test func punctuationGluedInsideATokenSplitsCorrectly() {
        // ". The" — the sentence ends INSIDE the token; the remainder
        // starts the next phrase.
        let phrases = speak(["It works", ". The", " ring", " holds."])
        #expect(phrases == ["It works.", " The ring holds."])
    }

    @Test func aBurstCanCompleteSeveralPhrasesInOneFeed() {
        // Burst-then-stall arrival: one token may close more than one
        // phrase; each is emitted, in order, from the same feed call.
        var phraser = SpeechPhraser()
        let burst = phraser.feed("Yes. No. Maybe")
        #expect(burst == ["Yes.", " No."])
        #expect(phraser.flush() == " Maybe")
    }

    @Test func flushDeliversTheRemainder() {
        // finishTokens with no trailing punctuation: the tail is spoken,
        // never swallowed.
        let phrases = speak(["and", " not", " an", " opinion"])
        #expect(phrases == ["and not an opinion"])
    }

    @Test func flushWithNothingWorthSayingIsNil() {
        var phraser = SpeechPhraser()
        _ = phraser.feed("Done.")
        #expect(phraser.flush() == nil)          // everything already left
        var empty = SpeechPhraser()
        _ = empty.feed("   ")
        #expect(empty.flush() == nil)            // whitespace is not a phrase
    }

    @Test func emptyAndWhitespaceTokensCompleteNothing() {
        var phraser = SpeechPhraser()
        #expect(phraser.feed("") == [])
        #expect(phraser.feed("   ") == [])
        #expect(phraser.feed("Hello") == [])
        #expect(phraser.feed("!") == ["Hello!"])
    }

    @Test func everyClauseMarkCuts() {
        // , ; : ? ! all end a phrase — clause rhythm, not only sentences.
        let phrases = speak(["a,", " b;", " c:", " d?", " e!", " f"])
        #expect(phrases == ["a,", " b;", " c:", " d?", " e!", " f"])
    }

    @Test func maxLengthCutsAtTheLastWhitespace() {
        // No punctuation anywhere: the limit forces a cut at the last
        // space before it, so no word is ever torn.
        let phrases = speak(
            ["aaaa", " bbbb", " cccc", " dddd"],
            config: .init(maxPhraseCharacters: 12))
        #expect(phrases == ["aaaa bbbb", " cccc dddd"])
    }

    @Test func oneUnbrokenRunIsCutHardAtTheLimit() {
        // A single run with no whitespace at all cannot wait forever:
        // the limit cuts it exactly.
        let phrases = speak(
            ["aaaaaaaaaa", "bbbbbbbbbb"],
            config: .init(maxPhraseCharacters: 10))
        #expect(phrases == ["aaaaaaaaaa", "bbbbbbbbbb"])
    }

    @Test func punctuationInsideANumberDoesNotCut() {
        // "3.14" — the mark must be followed by whitespace (or the end,
        // at flush) to count as a boundary.
        let phrases = speak(["pi", " is", " 3.14", " forever."])
        #expect(phrases == ["pi is 3.14 forever."])
    }
}
