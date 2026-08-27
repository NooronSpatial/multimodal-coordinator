import Foundation

/// ONE decode step: the wall time it took, and the audio it produced.
///
/// This is the record that did not exist, and its absence is why D-046's
/// sizing rule survived four milestones (D-080). `DecodeMargin` carries
/// whole-run numbers only — audio, wall, prefill, steady RTF — so nothing
/// in this project could see a STALL. It could only see an average, and
/// an average is exactly the statistic that cannot size a burst.
public struct DecodeStep: Sendable, Equatable {
    /// How long this step took.
    public let wallMilliseconds: Double
    /// How much audio it produced. May be ZERO: a step that emits no
    /// samples still costs time, and a run of them is precisely the
    /// stall this milestone exists to measure.
    public let audioMilliseconds: Double

    public init(wallMilliseconds: Double, audioMilliseconds: Double) {
        self.wallMilliseconds = wallMilliseconds
        self.audioMilliseconds = audioMilliseconds
    }
}

/// How deep the bank must be for the player never to run dry (4o, D-080,
/// F-1 = b) — **corrected by the review that followed**.
///
/// ## The model, stated properly this time
///
/// Three facts the first version got wrong, each confirmed by simulation
/// against the real `PlaybackLead`:
///
/// 1. **Playback does not begin at the run's birth.** It begins at `T0`,
///    the first moment enough audio is queued. Nothing drains before
///    that, so the LLM's time-to-first-clause and the decoder's prefill
///    are not deficit — they only delay the start. Banking them cost
///    500–2900 ms of pure felt pause in simulation.
/// 2. **A step's audio arrives at the END of the step.** The bank bottoms
///    out just before a slow step delivers, when `elapsed` has advanced
///    and `produced` has not. Crediting the step's own audio at that
///    instant understated the peak by one step.
/// 3. **A wall time is not an audio length.** The required start is a
///    WALL time; the cushion is an amount of AUDIO. They are equal only
///    when the decoder never runs ahead of real time — and `.fused`
///    measured 0.752, comfortably ahead, so the old rule under-banked
///    exactly where it looked safest.
///
/// ## The arithmetic
///
/// With playback starting at `T0` and the player draining in real time,
/// the audio available just before step `j` delivers is `produced(j−1)`,
/// and the audio consumed is `elapsed(j) − T0`. No underrun means
///
///     T0 ≥ elapsed(j) − produced(j−1)   for every j
///
/// so the player must not start before **`requiredStart`**, the maximum
/// of that quantity. The cushion is then simply *how much audio exists by
/// then* — which is what converts a wall time into the audio length
/// `PlaybackLead` compares against.
public enum DecodeDeficit {

    /// The wall time before which playback must not begin.
    ///
    /// Exposed separately because it is the honest intermediate: a reader
    /// comparing this against `DecodeMargin.prefillMilliseconds` can see
    /// at once whether a reply was late because the decoder stalled or
    /// because the model took its time before saying anything.
    public static func requiredStart(steps: some Sequence<DecodeStep>) -> Double {
        var elapsed = 0.0
        var producedBefore = 0.0
        var required = 0.0
        for step in steps {
            elapsed += step.wallMilliseconds
            // BEFORE crediting this step's audio: the bank is at its
            // lowest in the instant between the wall time being spent and
            // the samples arriving.
            required = max(required, elapsed - producedBefore)
            producedBefore += step.audioMilliseconds
        }
        return required
    }

    /// The audio that must be banked before playback starts.
    ///
    /// Zero for a decode that never needed to wait. **Conservative by at
    /// most one step's audio**, and deliberately so: playback can only
    /// begin on a buffer boundary, so the honest answer is the first
    /// boundary at or after `requiredStart` rather than a value between
    /// two of them that no player could act on.
    public static func cushion(steps: some Sequence<DecodeStep>) -> Double {
        let steps = Array(steps)
        let required = requiredStart(steps: steps)
        var elapsed = 0.0
        var produced = 0.0
        for step in steps {
            elapsed += step.wallMilliseconds
            produced += step.audioMilliseconds
            // The first buffer boundary at or after the required start.
            // Everything queued by then IS the cushion.
            if elapsed >= required { return produced }
        }
        return produced
    }
}

extension Duration {
    /// This duration in milliseconds.
    ///
    /// Open-coded in two places before 4o and about to become three, which
    /// is how two ways to state one fact begin. `components` rather than
    /// any Double conversion because attoseconds are exact integers here
    /// and the arithmetic should not visit a lossy type on the way.
    var milliseconds: Double {
        // INTEGER FIRST, and that is not fussiness. 50 ms is 5×10¹⁶
        // attoseconds, which is larger than 2⁵³ — so `Double(attoseconds)`
        // cannot hold it exactly and 50 ms arrives as 50.00000000000001.
        // The repo's own rule is that test values must be binary-exact,
        // and this helper feeds them: it broke AC-174's first run.
        //
        // So divide in `Int64` down to MICROSECONDS (10¹² attoseconds),
        // where the numbers are small enough to be exact, and only then
        // convert. Resolution is 1 µs, which is three orders finer than
        // any decode step this measures.
        let microseconds = components.seconds * 1_000_000
            + components.attoseconds / 1_000_000_000_000
        return Double(microseconds) / 1000
    }
}
