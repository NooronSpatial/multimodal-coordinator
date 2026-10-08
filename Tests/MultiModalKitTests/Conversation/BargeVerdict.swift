// THE VERDICT, NOT 2 s OF NOTHING (5d, D-143, F-42 A).
//
// A barge row used to prove "no barge" by spinning a CPU for 2 s, waiting for
// a state that must not come: about 12 s of busy CPU in the suite's first
// seconds, on CI's three cores, where the real-audio CONTROL row went red
// (SPEC §249). It now waits for FACTS:
//
//   the row's own events ─▶ the PROBE: an onset, and its end 7 ms later
//                              │ the audio stream is handled in order, so the
//                              ▼ probe is judged only after every event before it
//   the probe's verdict (abandoned)  ─or─  a barge (the reply cut, state .listening)
//
// A barge ends the wait too: `barge(for:)` switches the state in the same
// actor step that reports the verdict, before it awaits anything — and after
// a barge the probe raises no candidate (there is no reply left to guard).

import MultiModalKit
import Testing

enum BargeVerdict {

    /// The probe's length: no row raises a candidate judged 7 ms after its
    /// onset with nothing loud in it. 336 frames at 48 kHz — exact.
    static let probeLength = Duration.milliseconds(7)

    /// The probe, far past any row's own events (60 s on the audio timeline).
    static let probe: [AudioEvent] = [
        .speechStarted(utterance: 99, at: TurnCoordinatorTests.t(60_000 * 48)),
        .speechEnded(at: TurnCoordinatorTests.t(60_000 * 48 + 7 * 48)),
    ]

    static func isProbe(_ candidate: BargeCandidate) -> Bool {
        candidate.window == probeLength && candidate.loudTime == .zero
    }

    /// Sends the probe after the row's events, waits for the verdict, and
    /// says whether the reply was cut — with the candidates the row's own
    /// events raised (the probe's left out). Bounded: a coordinator that
    /// judges nothing fails the row, it does not hang it.
    static func judged(_ bench: TurnCoordinatorTests.Bench<ContinuousClock>,
                       _ recorder: CandidateRecorder) async -> (barged: Bool, candidates: [BargeCandidate]) {
        for event in probe { bench.audio.yield(event) }
        let decided = await TurnCoordinatorTests.until {
            if recorder.candidates.contains(where: isProbe) { return true }
            return await bench.coordinator.currentState == .listening
        }
        if !decided { Issue.record("no verdict: neither the probe was judged nor the reply cut") }
        let barged = await bench.coordinator.currentState == .listening
        return (barged, recorder.candidates.filter { !isProbe($0) })
    }
}
