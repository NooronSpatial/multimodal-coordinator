import Foundation
import MultiModalKit
import Testing

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

/// THE PHRASE CAP IS A MEMORY BOUND FOR ONE MOUTH (4q, D-084).
///
/// Qwen streams: it hands back samples as it goes, so how long a phrase
/// is barely touches what it allocates. Kokoro is StyleTTS 2 and returns
/// a whole phrase at once, so INSTRUMENTS §55 measured its transient
/// memory at **~120 MB per second of audio** on top of ~336 MB fixed.
/// Uncapped, that is an unbounded allocation on a phone already carrying
/// a 2.2 GB mind.
///
/// The cap therefore has to reach the phraser from the voice, and this
/// suite exists because a parameter that is accepted and quietly dropped
/// looks exactly like one that works. No model, no device, no network —
/// the scripted decoder reports what it was ASKED to decode, which is the
/// only evidence that matters here.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct PhraseCapTests {
    /// Deliberately one long clause with no sentence mark: the phraser
    /// cuts at clause boundaries first, so a text full of full stops
    /// would be cut by punctuation and prove nothing about the cap.
    static let unbrokenReply =
        "the audio travels through a ring buffer into a pump that cuts it "
        + "into small chunks and each chunk is handed to a listener that "
        + "decides whether the person is still speaking or has finally stopped"

    static func decodedPhrases(cap: Int?) async throws -> [String] {
        let decoder = ScriptedDecoder([])       // every decode simply succeeds
        let host = SpyPlaybackHost()
        let run = try NeuralVoiceRun(
            decoder: decoder, host: host,
            lead: PlaybackLead(target: .zero),
            phrasing: cap.map { SpeechPhraser.Config(maxPhraseCharacters: $0) }
                ?? SpeechPhraser.Config())
        await run.feed(Self.unbrokenReply)
        await run.finishTokens()
        for await _ in run.updates {}           // ends when the reply finishes
        return decoder.decodedTexts
    }

    /// Fact 1 — **the cap reaches the phraser at all.**
    ///
    /// The same words, twice, differing only in the number handed to the
    /// run. If the parameter were dropped on the way through, both sides
    /// would be identical and this comparison is what says so.
    @Test("a smaller cap cuts the same reply into more decodes")
    func aSmallerCapCutsMore() async throws {
        let wide = try await Self.decodedPhrases(cap: nil)      // the phraser's own 120
        let narrow = try await Self.decodedPhrases(cap: 20)

        #expect(!wide.isEmpty, "the reply must be decoded at all")
        #expect(narrow.count > wide.count,
                "20 must cut more often than 120, or the cap never reached the phraser")
    }

    /// Fact 2. **No phrase exceeds the cap**, which is the property the
    /// memory bound actually rests on. More cuts would be worthless if
    /// one of them could still be long.
    @Test("no decoded phrase is longer than the cap it was given")
    func noPhraseExceedsTheCap() async throws {
        let cap = 20
        let phrases = try await Self.decodedPhrases(cap: cap)
        #expect(!phrases.isEmpty)
        for phrase in phrases {
            #expect(phrase.count <= cap,
                    "\"\(phrase)\" is \(phrase.count) characters against a cap of \(cap)")
        }
    }

    /// Fact 3. **Nothing is lost at a cut.** A cap that dropped words
    /// would be a memory bound bought with the person's sentence, and the
    /// bug would be inaudible in a test that only counted phrases.
    @Test("cutting harder never drops a word")
    func cuttingNeverDropsAWord() async throws {
        let wide = try await Self.decodedPhrases(cap: nil)
        let narrow = try await Self.decodedPhrases(cap: 20)
        let words = { (phrases: [String]) in
            phrases.joined(separator: " ").split(separator: " ").map(String.init)
        }
        #expect(words(narrow) == words(wide),
                "the same words, in the same order, however they are grouped")
    }

    /// Fact 4. The default this mouth ships is the one §55's arithmetic
    /// produced, and it is half the phraser's own.
    ///
    /// A constant compared to a literal proves little on its own — what
    /// it pins is that the number cannot drift back to the streaming
    /// mouth's default without someone editing this line and meeting the
    /// reason in the doc comment beside it.
    @Test("Kokoro's default cap is the measured 60, not the phraser's 120")
    func kokoroDefaultsToTheMeasuredCap() {
        #expect(KokoroVoice.phraseCharacters == 60)
        #expect(SpeechPhraser.Config().maxPhraseCharacters == 120,
                "the streaming mouth is untouched by this bound")
    }
}
#endif
