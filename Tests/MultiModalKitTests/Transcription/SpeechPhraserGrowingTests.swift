// 5d PIECE 2 — GROWING PHRASES (SPEC §235/2; F-34 A, AC-350).
//
//   today:    [The first law of thermodynamics states that energy cannot be created or destroyed,] …
//             └──────────── the voice waits for ALL of this, then synthesizes all of it ────────────┘
//   growing:  [The first law of][ thermodynamics states that energy][ cannot be created or destroyed,] …
//              ≤ 20               ≤ 40                                ≤ 120, as today
//
// Pure, like the rest of the phraser's rows: tokens in, phrases out. Word
// tokens carry their own leading space, the way real generators emit them.

import MultiModalKit
import Testing

@Suite("AC-350 · growing phrases", .timeLimit(.minutes(1)))
struct SpeechPhraserGrowingTests {

    static let growing = SpeechPhraser.Config(openingCaps: [20, 40])

    /// Every phrase the text makes, fed as `tokens`, then flushed.
    static func phrases(_ tokens: [String], _ config: SpeechPhraser.Config = growing) -> [String] {
        var phraser = SpeechPhraser(config: config)
        var out = tokens.flatMap { phraser.feed($0) }
        if let rest = phraser.flush() { out.append(rest) }
        return out
    }

    /// Words with their leading spaces: "a b c" → ["a", " b", " c"].
    static func words(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated()
            .map { $0.offset == 0 ? String($0.element) : " " + $0.element }
    }

    static let firstLaw = "The first law of thermodynamics states that energy cannot be created or destroyed,"
        + " only transformed from one form to another."

    @Test("the first phrases grow: 20, then 40, then the usual 120 — each at the last space before its cap")
    func theFirstPhrasesGrow() {
        #expect(Self.phrases(Self.words(Self.firstLaw)) == [
            "The first law of",
            " thermodynamics states that energy",
            " cannot be created or destroyed,",
            " only transformed from one form to another."
        ])
    }

    @Test("a clause mark that comes before the cap still wins")
    func aClauseMarkStillWins() {
        let reply = "Sure! Here's a simple recipe for you: grilled chicken with spinach."
        #expect(Self.phrases(Self.words(reply)) == [
            "Sure!",
            " Here's a simple recipe for you:",
            " grilled chicken with spinach."
        ])
    }

    @Test("a reply shorter than the first cap is one phrase, as today")
    func aShortReplyIsOnePhrase() {
        #expect(Self.phrases(["Okay."]) == ["Okay."])
        #expect(Self.phrases(Self.words("I can help.")) == ["I can help."])
    }

    @Test("one unbroken word longer than an opening cap stays WHOLE — never torn at 20")
    func aLongWordStaysWhole() {
        let reply = "Pneumonoultramicroscopicsilicovolcanoconiosis is a long word for a lung disease."
        #expect(Self.phrases(Self.words(reply)) == [
            "Pneumonoultramicroscopicsilicovolcanoconiosis",
            " is a long word for a lung disease."
        ])
    }

    @Test("an unbroken run past the 120 limit is still cut at 120: the memory bound outranks the opening cap")
    func theLimitStillBinds() {
        let run = String(repeating: "x", count: 150)
        let phrases = Self.phrases([run, " end."])
        #expect(phrases.first?.count == 120, "the first phrase: \(phrases.first?.count ?? 0) characters")
    }

    @Test("after the opening caps, phrases are cut at 120 again — and nothing is lost or invented")
    func thenTheUsualCap() throws {
        let reply = "Here is a long answer without any marks at all that goes on and on about the history"
            + " of the city and its people and its many old buildings and its long winding streets"
            + " and the river that runs through the middle of it all"
        let phrases = Self.phrases(Self.words(reply))
        // REQUIRED, not expected: the rows below index the phrases, and an
        // index past the end crashes the whole test process (its first red
        // run did exactly that) — a red row must fail, never crash.
        try #require(phrases.count >= 4, "phrases: \(phrases.count)")
        #expect(phrases[0].count <= 20 && phrases[1].count <= 40)
        #expect(phrases[2].count > 40 && phrases[2].count <= 120,
                "the third phrase may be long again: \(phrases[2].count) characters")
        #expect(phrases.joined() == reply, "verbatim: the phraser never drops or invents a character")
    }

    @Test("tokens at any granularity give the same phrases")
    func anyGranularity() {
        let byWord = Self.phrases(Self.words(Self.firstLaw))
        let byCharacter = Self.phrases(Self.firstLaw.map(String.init))
        #expect(byCharacter == byWord)
    }

    /// The bakeoff's long fixture, which found the next two rows: it is fed
    /// to the voice in ONE `feed`, and its first phrase ran to the comma.
    static let longFixture = "The audio travels through a ring buffer into a pump that cuts it into small chunks,"
        + " and each chunk is handed to a listener that decides whether the person is still speaking"
        + " or has finally stopped and is waiting for an answer."

    @Test("a whole reply fed in ONE burst gives the same phrases as word by word")
    func aBurstGivesTheSamePhrases() {
        for reply in [Self.firstLaw, Self.longFixture] {
            #expect(Self.phrases([reply]) == Self.phrases(Self.words(reply)), "\(reply.prefix(30))…")
        }
    }

    @Test("with no opening caps too: a mark beyond the 120 limit never stretches a burst's phrase past it")
    func aBurstRespectsTheLimit() {
        let reply = String(repeating: "word ", count: 26) + "end, and the rest."     // the comma at 133
        let config = SpeechPhraser.Config()
        let burst = Self.phrases([reply], config)
        #expect(burst == Self.phrases(Self.words(reply), config))
        #expect(burst.allSatisfy { $0.count <= 120 }, "a burst made \(burst.map(\.count)) characters")
    }

    @Test("with no opening caps, nothing changes")
    func noCapsNothingChanges() {
        #expect(Self.phrases(Self.words(Self.firstLaw), SpeechPhraser.Config()) == [
            "The first law of thermodynamics states that energy cannot be created or destroyed,",
            " only transformed from one form to another."
        ])
    }
}
