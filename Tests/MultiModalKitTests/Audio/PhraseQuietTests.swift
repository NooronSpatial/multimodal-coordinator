// 5d PIECE 2 — THE QUIET AROUND A PHRASE (SPEC §235/1; F-32 A, F-33 A, AC-348).
//
//   what the voice made:  ░░░░░░░░[ the words ]░░░░░░░░░░░
//   what is kept:            ░░[ the words ]░░░░
//                        margin              the closing mark's pause
//
// The rule is pure: scripted samples with KNOWN quiet in, an exact range
// out. 16 kHz, so every stretch is a whole number of frames and every
// duration below is exact (1 ms = 16 frames), as in `SilenceMeterTests`.

import MultiModalKit
import Testing

@Suite("AC-348 · the quiet around a phrase")
struct PhraseQuietTests {

    static let rate = 16_000.0

    static func sound(_ milliseconds: Int, level: Float = 0.5) -> [Float] {
        Array(repeating: level, count: milliseconds * 16)
    }
    static func quiet(_ milliseconds: Int, level: Float = 0.0004) -> [Float] {
        Array(repeating: level, count: milliseconds * 16)      // the model's quiet: low, never exact zeros
    }
    static func frames(_ milliseconds: Int) -> Int { milliseconds * 16 }

    /// 40 ms of margin; 150 ms after a comma, 350 after a full stop.
    static let trim = PhraseQuiet(config: .init(
        margin: .milliseconds(40),
        pauses: [",": .milliseconds(150), ".": .milliseconds(350)]))

    @Test("the margin before the first loud sample, and the mark's pause after the last — exactly")
    func keepsTheMarginAndTheMarksPause() {
        let phrase = Self.quiet(325) + Self.sound(400) + Self.quiet(420)
        let kept = Self.trim.kept(phrase, closingMark: ",", sampleRate: Self.rate)
        #expect(kept == Self.frames(325 - 40)..<Self.frames(325 + 400 + 150))
    }

    @Test("the closing mark chooses the pause")
    func theMarkChoosesThePause() {
        let phrase = Self.quiet(325) + Self.sound(400) + Self.quiet(420)
        let kept = Self.trim.kept(phrase, closingMark: ".", sampleRate: Self.rate)
        #expect(kept.upperBound == Self.frames(325 + 400 + 350))
    }

    @Test("a phrase that closes on no mark the table knows keeps only the margin after its words")
    func noMarkKeepsTheMargin() {
        let phrase = Self.quiet(325) + Self.sound(400) + Self.quiet(420)
        #expect(Self.trim.kept(phrase, closingMark: nil, sampleRate: Self.rate).upperBound
                == Self.frames(325 + 400 + 40), "a cap cut")
        #expect(Self.trim.kept(phrase, closingMark: "؟", sampleRate: Self.rate).upperBound
                == Self.frames(325 + 400 + 40), "a mark with no pause in the table")
    }

    @Test("less quiet than the rule asks for: all of it is kept")
    func lessQuietIsAllKept() {
        let phrase = Self.quiet(20) + Self.sound(400) + Self.quiet(60)
        #expect(Self.trim.kept(phrase, closingMark: ",", sampleRate: Self.rate) == 0..<phrase.count)
    }

    @Test("the quiet INSIDE the words stays: only the edges are shortened")
    func theInsideStays() {
        let words = Self.sound(150) + Self.quiet(500) + Self.sound(150)
        let phrase = Self.quiet(325) + words + Self.quiet(420)
        let kept = Self.trim.kept(phrase, closingMark: ".", sampleRate: Self.rate)
        #expect(kept == Self.frames(325 - 40)..<Self.frames(325 + 800 + 350),
                "a 500 ms pause between the words is the voice's own phrasing")
    }

    @Test("never a loud sample: words that touch both edges come back whole")
    func neverALoudSample() {
        let phrase = Self.sound(400)
        #expect(Self.trim.kept(phrase, closingMark: ",", sampleRate: Self.rate) == 0..<phrase.count)
    }

    @Test("nothing loud at all: the samples come back unchanged")
    func nothingLoudIsUnchanged() {
        let phrase = Self.quiet(800)
        #expect(Self.trim.kept(phrase, closingMark: ".", sampleRate: Self.rate) == 0..<phrase.count)
        #expect(Self.trim.kept([], closingMark: ".", sampleRate: Self.rate) == 0..<0)
    }

    @Test("the level is the meter's: a sample AT the level is loud, one just under it is quiet")
    func theLevelIsTheMeters() {
        let atLevel = Self.quiet(325) + [0.001] + Self.quiet(325)
        #expect(Self.trim.kept(atLevel, closingMark: nil, sampleRate: Self.rate)
                == Self.frames(325 - 40)..<(Self.frames(325) + 1 + Self.frames(40)))
        let under = Self.quiet(325) + [0.000_999] + Self.quiet(325)
        #expect(Self.trim.kept(under, closingMark: nil, sampleRate: Self.rate) == 0..<under.count,
                "nothing loud")
    }

    @Test("a phrase's closing mark is its last character that is not a space, when the phraser cuts there")
    func theClosingMark() {
        #expect(PhraseQuiet.closingMark(of: "into small chunks,") == ",")
        #expect(PhraseQuiet.closingMark(of: " Sure! ") == "!")
        #expect(PhraseQuiet.closingMark(of: "How can I help you today?") == "?")
        #expect(PhraseQuiet.closingMark(of: "Here is the plan:") == ":")
        #expect(PhraseQuiet.closingMark(of: "The first law of") == nil, "a cap cut")
        #expect(PhraseQuiet.closingMark(of: "3.14") == nil)
        #expect(PhraseQuiet.closingMark(of: "   ") == nil)
    }
}
