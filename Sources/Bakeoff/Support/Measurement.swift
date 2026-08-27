// The bake-off's stopwatch, shared by every instrument in this tool:
// `MarginBox`, which carries one decode's margin across threads, and
// `measure`, which times one reply through any mouth.
import Foundation
import MultiModalKit
import MultiModalKitTTS
import Synchronization

/// Drives one reply through a mouth and times the two moments that
/// matter: when sound STARTS, and when the room goes quiet.
/// One reply's margin, handed across threads.
///
/// `reportMargins` delivers on whatever thread finished the decode, and
/// the sweep reads on its own — so the value crosses a boundary and needs
/// the lock. The rules are this repo's usual two: nothing but the store
/// happens under it, and it is never held across a suspension point.
final class MarginBox: Sendable {
    private let box = Mutex<DecodeMargin?>(nil)
    func record(_ margin: DecodeMargin) { box.withLock { $0 = margin } }
    /// Reads AND clears: a run that reported nothing must not silently
    /// inherit the previous run's number.
    func take() -> DecodeMargin? {
        box.withLock { stored in
            let margin = stored
            stored = nil
            return margin
        }
    }
    func reset() { _ = take() }
}

/// One spoken utterance, timed.
///
/// `completed` is the half the 4o review found missing: a decode that
/// FAILS still returns timings, and every caller treated them as a
/// result. `AdaptiveLead` has guarded this since 4m — `guard
/// margin.completed` — while the measuring tools had no equivalent, so a
/// broken run could be graded and folded into a median. A failure is
/// still not thrown here, because a sweep wants to record the row and
/// carry on; it is REPORTED, and the caller must look.
/// What one timed utterance produced.
struct Timing {
    let firstAudio: Double
    let total: Double
    /// False when the decode reported `.failed`. The 4o review found every
    /// caller treating a broken run's numbers as a result.
    let completed: Bool
}

func measure(_ mouth: any SpeechSynthesizing, _ text: String) async throws
    -> Timing {
    let run = try await mouth.openUtterance()
    var failed = false
    let clock = ContinuousClock()
    let t0 = clock.now
    var firstAudio: Duration?

    // THE READER RUNS FIRST, AND THAT IS A CORRECTION.
    //
    // The first version of this function fed the whole sentence,
    // closed it, and only THEN read the update stream. That is fair
    // to Apple, whose `feed` hands the text to the framework and
    // returns at once — and deeply unfair to the neural mouth, whose
    // `feed` does not return until the decode is finished. Its
    // `.started` was sent on time and sat buffered in the stream;
    // this function stamped it when it finally READ it. The result
    // was a first-audio number that was really a total, and a 202x
    // ratio that measured a mistake.
    //
    // The tell was in the table: neural first-audio within ~100 ms
    // of neural total, on every single row. A step trace settled it
    // — audio steps arrive every ~80 ms from the start.
    //
    // So: this task parks on the stream, and the FEEDING moves to a
    // child. The gate below is why there is no sleep here — the
    // feeder waits for a fact, not for a guess (the determinism rule).
    let gate = AsyncStream<Void>.makeStream()
    let feeder = Task {
        for await _ in gate.stream { break }
        await run.feed(text)
        await run.finishTokens()
    }
    gate.continuation.finish()      // opens the gate: the feeder may go
    for await update in run.updates {
        switch update {
        case .started: if firstAudio == nil { firstAudio = t0.duration(to: clock.now) }
        case .failed(let why):
            print("   ⚠️  \(why)")
            failed = true
        case .finished: break
        }
    }
    let total = t0.duration(to: clock.now)
    await feeder.value
    func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15
    }
    return Timing(firstAudio: firstAudio.map(ms) ?? -1,
                  total: ms(total), completed: !failed)
}
