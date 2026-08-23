import Foundation
import MultiModalKit

/// Times one utterance: how long until sound starts, and how long until it
/// ends.
///
/// ## The correction this type exists to hold
///
/// The first version of this measurement — in `bakeoff` — fed the whole
/// sentence, closed it, and only THEN read the update stream. That is fair
/// to Apple's mouth, whose `feed` hands text to the framework and returns at
/// once. It is deeply unfair to the neural mouth, whose `feed` does not
/// return until the decode has finished: its `.started` was sent on time and
/// sat buffered in the stream, and the measurement stamped it when it
/// finally got around to READING it.
///
/// The result was a first-audio number that was really a total, and a
/// published ratio of 202× that measured nothing but the mistake. The tell
/// was in the table — neural first-audio within ~100 ms of neural total, on
/// every single row.
///
/// So the reader parks on the stream FIRST and the feeding happens in a
/// child task. The gate below is why there is no sleep: the feeder waits for
/// a fact, not for an interval.
///
/// It lives here, rather than in the two places that need it, because the
/// phone bench and the Mac bake-off must not drift apart — and because a
/// mistake this quiet deserves a test rather than a comment.
///
/// ## The limit of this measurement, stated
///
/// An `AsyncStream` update is stamped **when the consumer observes it**, not
/// when the producer sends it. So this number is only as good as the
/// reader's wake-up. In production that gap is microseconds and the Mac's
/// own figures show it — 191 ms first audio against 6578 ms total, on a run
/// where the two would be equal if the reader were arriving late.
///
/// Writing the tests for this made the limit impossible to ignore: under a
/// manual clock, an update sent before the reader parks is stamped after
/// every advance the test performs, and first audio comes out **equal to
/// total** — the 202× mistake, reproduced from the other side. The tests
/// therefore let the reader observe each event before time moves again.
/// That is a property of the measurement, not a trick to make them pass, and
/// the alternative — a send-time stamp — would mean putting a timestamp
/// inside `SynthesisUpdate`, which no other caller needs.
public enum UtteranceStopwatch {

    public static func time(
        _ mouth: any SpeechSynthesizing,
        saying text: String,
        clock: some Clock<Duration>
    ) async throws -> BenchTiming {
        let run = try await mouth.openUtterance()
        let start = clock.now
        var firstAudio: Duration?

        let gate = AsyncStream<Void>.makeStream()
        let feeder = Task {
            for await _ in gate.stream { break }
            await run.feed(text)
            await run.finishTokens()
        }
        gate.continuation.finish()          // the feeder may go

        for await update in run.updates {
            switch update {
            case .started:
                // FIRST one only. A mouth that reports started twice must
                // not move the number it already earned.
                if firstAudio == nil { firstAudio = start.duration(to: clock.now) }
            default:
                break
            }
        }
        let total = start.duration(to: clock.now)
        await feeder.value
        // `.zero` when a mouth finished without ever starting — a failed
        // decode, or a cancel. Reported as zero rather than as a plausible
        // small number, so a row that never spoke cannot read as a fast one.
        return BenchTiming(firstAudio: firstAudio ?? .zero, total: total)
    }
}
