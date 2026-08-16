import Testing
import Foundation
@testable import MultiModalKit

/// THE LEAD (AC-107, D-046 = A). A streaming voice that starts playing
/// the instant the first buffer arrives has NO margin: if the decoder
/// produces audio slower than the ear drinks it, the player runs dry and
/// the speech gaps. AC-102 measured exactly that — RTF 1.09–1.23, and a
/// long sentence that ended at decode wall time instead of at
/// first-audio + audio.
///
/// The rule that fixes it is small enough to be pure, so it is: no
/// clock, no player, no model. What is provable here is provable
/// everywhere, and the neural mouth's own tests can then be about the
/// neural mouth.
@Suite("The playback lead — when it is safe to start speaking")
struct PlaybackLeadTests {

    // Durations are whole milliseconds throughout: integer arithmetic,
    // binary-exact, no float rounding anywhere near a test expectation.
    let target = Duration.milliseconds(800)

    @Test("enough audio queued starts playback")
    func reachingTheTargetStarts() {
        var lead = PlaybackLead(target: target)
        #expect(lead.queue(.milliseconds(300)) == false)
        #expect(lead.queue(.milliseconds(300)) == false)
        #expect(lead.queue(.milliseconds(300)) == true, "900 ms passes an 800 ms target")
    }

    @Test("the exact boundary starts — the target is a floor, not a fence")
    func exactlyTheTargetStarts() {
        var lead = PlaybackLead(target: target)
        #expect(lead.queue(.milliseconds(800)) == true)
    }

    @Test("below the target waits, however many buffers arrive")
    func belowTheTargetWaits() {
        var lead = PlaybackLead(target: target)
        for _ in 0..<9 {
            #expect(lead.queue(.milliseconds(80)) == false)
        }
        #expect(lead.queuedAudio == .milliseconds(720))
        #expect(lead.hasStarted == false)
    }

    /// THE LIVENESS PROMISE, in the one place it can be proven cheaply.
    /// A four-word reply is shorter than the lead and always will be. If
    /// the rule waited for a target that nothing will ever deliver, the
    /// mouth would go silent forever and the turn would hang — the exact
    /// failure `SynthesizerConformanceKit`'s promise 4 exists to catch,
    /// one layer down where it needs a model and a speaker to see.
    @Test("a reply that ends before the lead still plays")
    func endingEarlyStartsAnyway() {
        var lead = PlaybackLead(target: target)
        #expect(lead.queue(.milliseconds(240)) == false)
        #expect(lead.noMoreAudio() == true, "all there will ever be is all we wait for")
    }

    @Test("a silent reply starts nothing")
    func silentReplyStartsNothing() {
        var lead = PlaybackLead(target: target)
        #expect(lead.noMoreAudio() == false, "no audio means nothing to start")
        #expect(lead.hasStarted == false)
    }

    @Test("playback starts exactly once, however much more arrives")
    func startsOnlyOnce() {
        var lead = PlaybackLead(target: target)
        #expect(lead.queue(.milliseconds(800)) == true)
        #expect(lead.queue(.milliseconds(800)) == false)
        #expect(lead.noMoreAudio() == false)
        #expect(lead.hasStarted == true)
    }

    /// `noMoreAudio` after the lead is already released must not fire a
    /// second start: the caller uses the `true` to touch the player, and
    /// touching it twice is a bug that only hardware would show.
    @Test("the end of the reply cannot re-start an already-playing reply")
    func endAfterStartIsSilent() {
        var lead = PlaybackLead(target: target)
        _ = lead.queue(.milliseconds(900))
        #expect(lead.noMoreAudio() == false)
    }

    @Test("an abandoned reply starts nothing, before or after the target")
    func abandonedStartsNothing() {
        var early = PlaybackLead(target: target)
        early.abandon()
        #expect(early.queue(.milliseconds(5_000)) == false)
        #expect(early.noMoreAudio() == false)
        #expect(early.hasStarted == false)

        // And abandoning a reply that is ALREADY playing must not report
        // a start either — the barge case, where the run tears down the
        // player itself.
        var late = PlaybackLead(target: target)
        #expect(late.queue(.milliseconds(900)) == true)
        late.abandon()
        #expect(late.queue(.milliseconds(900)) == false)
        #expect(late.noMoreAudio() == false)
    }

    /// A zero target is "start on the first buffer" — the behaviour AC-102
    /// measured, kept reachable so the OLD number can be reproduced
    /// against the new code rather than remembered from a table.
    @Test("a zero target reproduces the un-buffered behaviour exactly")
    func zeroTargetStartsImmediately() {
        var lead = PlaybackLead(target: .zero)
        #expect(lead.queue(.milliseconds(80)) == true, "first buffer, no waiting")
    }

    /// Empty buffers must not release the lead. A decoder that emits a
    /// zero-sample step (or a caller that hands one on) would otherwise
    /// "reach" a zero target and start a player with nothing in it.
    @Test("empty audio moves nothing")
    func emptyAudioIsNotProgress() {
        var lead = PlaybackLead(target: target)
        #expect(lead.queue(.zero) == false)
        #expect(lead.queuedAudio == .zero)
        #expect(lead.noMoreAudio() == false, "still a silent reply")
    }

    /// The sizing rule the milestone actually needs, stated as a test so
    /// it is checked rather than remembered: to stay gapless, the lead
    /// must cover the decoder's cumulative deficit over the whole reply,
    /// which is `replyLength × (RTF − 1)`.
    @Test("the sizing rule covers a measured deficit")
    func sizingCoversTheDeficit() {
        // AC-102's worst measured factor, as exact integer milliseconds.
        let reply = Duration.milliseconds(8_000)
        let deficit = PlaybackLead.deficit(forReplyOf: reply, realTimeFactor: 1.25)
        #expect(deficit == .milliseconds(2_000))

        var lead = PlaybackLead(target: deficit)
        #expect(lead.queue(.milliseconds(1_999)) == false)
        #expect(lead.queue(.milliseconds(1)) == true)
    }

    @Test("a decoder that keeps ahead needs no lead at all")
    func noDeficitWhenFastEnough() {
        #expect(PlaybackLead.deficit(forReplyOf: .milliseconds(8_000),
                                     realTimeFactor: 0.8) == .zero)
        #expect(PlaybackLead.deficit(forReplyOf: .milliseconds(8_000),
                                     realTimeFactor: 1.0) == .zero)
    }
}

/// IS THERE ANYTHING TO SAY? (AC-106, found by a hanging test.)
///
/// The conformance kit's liveness promise feeds a long run of whitespace,
/// which the phraser cuts into several whitespace-only phrases. Apple's
/// mouth shrugs at those. The neural mouth does not: with no letters to
/// end on, the model has no reason to stop, so each one decodes toward
/// `maxNewTokens` — 245 steps, about 19.6 SECONDS of audio, for a phrase
/// containing nothing. Several of those in a row ran the suite past its
/// four-minute limit, sometimes; other times the model happened to stop
/// early and the test passed in 9 seconds. A test whose duration depends
/// on when a language model feels like stopping is flaky by construction.
///
/// It is a product fault before it is a test fault. In a live turn, one
/// stray whitespace phrase would buy twenty seconds of dead air while the
/// coordinator waited for a `finished` that was busy decoding silence.
@Suite("Is there anything worth speaking?")
struct SpeakableContentTests {

    @Test("ordinary text is speakable")
    func wordsAreSpeakable() {
        #expect(SpeechPhraser.hasSpeakableContent("Hello."))
        #expect(SpeechPhraser.hasSpeakableContent("   trailing and leading   "))
        #expect(SpeechPhraser.hasSpeakableContent("a"))
    }

    @Test("digits are speakable — a number is a word out loud")
    func digitsAreSpeakable() {
        #expect(SpeechPhraser.hasSpeakableContent("42"))
        #expect(SpeechPhraser.hasSpeakableContent(" 7 "))
    }

    @Test("whitespace alone is not speakable — the case that hung the suite")
    func whitespaceIsNotSpeakable() {
        #expect(!SpeechPhraser.hasSpeakableContent(""))
        #expect(!SpeechPhraser.hasSpeakableContent(" "))
        #expect(!SpeechPhraser.hasSpeakableContent(String(repeating: " ", count: 200)))
        #expect(!SpeechPhraser.hasSpeakableContent("\n\t  \n"))
    }

    @Test("punctuation alone is not speakable")
    func punctuationIsNotSpeakable() {
        #expect(!SpeechPhraser.hasSpeakableContent("..."))
        #expect(!SpeechPhraser.hasSpeakableContent("   ...   "))
        #expect(!SpeechPhraser.hasSpeakableContent("—,;:!?"))
    }

    /// Not English-only. A rule that asked for A–Z would silently mute
    /// every other writing system, which is a worse bug than the one it
    /// was written to fix.
    @Test("other writing systems are speakable")
    func otherScriptsAreSpeakable() {
        #expect(SpeechPhraser.hasSpeakableContent("مرحبا"))
        #expect(SpeechPhraser.hasSpeakableContent("こんにちは"))
        #expect(SpeechPhraser.hasSpeakableContent("Привет"))
        #expect(SpeechPhraser.hasSpeakableContent("é"))
    }
}
