import Foundation
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import Testing

/// The measurement that was once wrong by a whole order of magnitude.
///
/// `bakeoff` published a 202× neural-vs-Apple ratio that measured its own
/// reader arriving late, not a decoder being slow. These tests pin the
/// behaviour that fixed it: `.started` is stamped WHEN IT IS SENT, even
/// though the feed has not returned.
@Suite("timing one utterance")
struct UtteranceStopwatchTests {

    /// Gate on the FACT that the utterance is open, never on luck.
    ///
    /// The first version of these tests reported `.started` immediately
    /// after spawning the timing task, and the report landed before
    /// `openUtterance` had registered a continuation — so it went nowhere,
    /// the terminal never arrived, and the test HUNG. A red test that hangs
    /// is the one thing CLAUDE.md §3.3 forbids outright, so the wait is
    /// bounded and fails fast.
    private func waitUntilReading(_ mouth: ScriptedSynthesizer) async {
        for _ in 0 ..< 10_000 {
            if mouth.utterancesOpened == 1 { break }
            await Task.yield()
        }
        guard mouth.utterancesOpened == 1 else {
            Issue.record("the utterance never opened")
            return
        }
        // AND THEN LET THE READER PARK. This is an ORDERING wait, not a time
        // wait — yields, never a clock — but it is a real limitation and it
        // is the same one the production code has: `AsyncStream` stamps an
        // update when the CONSUMER observes it, not when the producer sends
        // it. A reader that has not reached its `for await` yet will stamp
        // late, and under a manual clock "late" means "after every advance
        // the test performs", which reads as first-audio == total — the
        // exact shape of the 202x mistake this file exists to pin.
        //
        // In production the reader is parked microseconds after `open`, and
        // the Mac's numbers show it: 191 ms first audio against 6578 ms
        // total, on a run where the two would be equal if this were broken.
        for _ in 0 ..< 100 { await Task.yield() }
    }

    /// Let the reader OBSERVE what was just sent, before the clock moves
    /// again. Without this the update sits in the stream while the test
    /// advances time, and the reader stamps it at the later instant — which
    /// is not a flaw in the test but the very thing being measured: an
    /// `AsyncStream` update is stamped when it is READ.
    private func letTheReaderCatchUp() async {
        for _ in 0 ..< 100 { await Task.yield() }
    }

    @Test("first audio is stamped at `.started`, not when the feed returns")
    func firstAudioIsNotTheTotal() async throws {
        let clock = ManualClock()
        let mouth = ScriptedSynthesizer.manual(utterances: 1)
        mouth.releaseOpen()

        let timing = Task {
            try await UtteranceStopwatch.time(mouth, saying: "hello", clock: clock)
        }
        await waitUntilReading(mouth)
        // The mouth speaks at 100 ms and finishes at 900 ms. A reader that
        // only looked after the feed returned would report both as 900.
        await clock.advance(by: .milliseconds(100))
        mouth.reportStarted(utterance: 0)
        await letTheReaderCatchUp()
        await clock.advance(by: .milliseconds(800))
        mouth.reportFinished(utterance: 0)

        let measured = try await timing.value
        #expect(measured.firstAudio == .milliseconds(100))
        #expect(measured.total == .milliseconds(900))
        #expect(measured.firstAudio != measured.total,
                "these being equal is the exact shape of the 202x mistake")
    }

    @Test("a second `.started` does not move the number already earned")
    func firstStartedWins() async throws {
        let clock = ManualClock()
        let mouth = ScriptedSynthesizer.manual(utterances: 1)
        mouth.releaseOpen()

        let timing = Task {
            try await UtteranceStopwatch.time(mouth, saying: "hello", clock: clock)
        }
        await waitUntilReading(mouth)
        await clock.advance(by: .milliseconds(50))
        mouth.reportStarted(utterance: 0)
        await letTheReaderCatchUp()
        await clock.advance(by: .milliseconds(200))
        mouth.reportStarted(utterance: 0)
        await letTheReaderCatchUp()
        await clock.advance(by: .milliseconds(50))
        mouth.reportFinished(utterance: 0)

        #expect(try await timing.value.firstAudio == .milliseconds(50))
    }

    @Test("a mouth that never speaks reports zero, not a plausibly fast number")
    func silenceIsZeroNotFast() async throws {
        let clock = ManualClock()
        let mouth = ScriptedSynthesizer.manual(utterances: 1)
        mouth.releaseOpen()

        let timing = Task {
            try await UtteranceStopwatch.time(mouth, saying: "hello", clock: clock)
        }
        await waitUntilReading(mouth)
        await clock.advance(by: .milliseconds(300))
        mouth.reportFailed(utterance: 0, reason: "decode failed")
        mouth.reportFinished(utterance: 0)

        let measured = try await timing.value
        #expect(measured.firstAudio == .zero,
                "a row that never spoke must not read as the fastest row")
        #expect(measured.total == .milliseconds(300))
    }
}
