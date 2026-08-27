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
/// F-1 = b).
///
/// ## The arithmetic, because it is the whole ruling
///
/// While a reply plays, the bank holds
///
///     cushion + (audio produced so far) − (audio played so far)
///
/// and the player drinks in real time, so "audio played" IS elapsed wall
/// time once playback has started. The bank empties exactly when
///
///     cushion < (elapsed − produced)
///
/// at ANY moment — so the cushion must cover the **running maximum** of
/// that difference. Not its value at the end, and not the largest single
/// step.
///
/// ## Why the old rule looked right for four milestones
///
/// `replyLength × (RTF − 1)` IS this running maximum — *when the decode
/// rate is uniform*. Under a constant rate the deficit climbs steadily
/// and its maximum is its final value, which is what that formula
/// computes. Uniformity was the false assumption; the arithmetic was
/// never wrong. The decoder stalls, and a stall reaches a peak the
/// endpoint never records.
///
/// ## Why not the worst single step (F-1's rejected half)
///
/// Five 200 ms overruns in a row drain a bank exactly as one 1000 ms
/// overrun does. A per-step maximum cannot see them, so it under-sizes
/// precisely when the decoder is persistently — rather than
/// spectacularly — late.
public enum DecodeDeficit {
    /// The deepest the bank ever has to be, in milliseconds.
    ///
    /// Returns 0 for an empty sequence and for any decode that never
    /// falls behind — a decoder faster than the ear needs no cushion, and
    /// saying "0" is the honest answer rather than a floor in disguise.
    public static func worstLag(steps: some Sequence<DecodeStep>) -> Double {
        var elapsed = 0.0
        var produced = 0.0
        var worst = 0.0
        for step in steps {
            elapsed += step.wallMilliseconds
            produced += step.audioMilliseconds
            worst = max(worst, elapsed - produced)
        }
        return worst
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
