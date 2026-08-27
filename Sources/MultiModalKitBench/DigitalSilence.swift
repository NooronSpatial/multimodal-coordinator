import Foundation

/// The dropout metric that needs no chosen threshold (4o, AC-178).
///
/// ## Why exact zeros, and not an amplitude floor
///
/// The 2026-08-27 session first measured dropouts with an invented
/// amplitude floor of 0.005. The adversarial review killed it: the floor
/// cut straight through quiet-but-real speech, counting soft syllables as
/// dropouts, and it was knife-edge — the same recording read 9 or 68 ms
/// per second as the floor moved from 0.002 to 0.010. It produced a
/// confident false conclusion (a "residual no cushion can fix") that
/// contained not one silent sample.
///
/// **When an `AVAudioPlayerNode` runs dry, the mixer renders exact
/// zeros.** Speech never is exactly zero. INSTRUMENTS §53 records this
/// agreeing with Ryad's ear on the two files he judged: 13 runs in the
/// one he called hitchy, none in the one he called better.
///
/// ## It is not threshold-FREE, and calling it that was wrong
///
/// The 4o review caught the overclaim. The AMPLITUDE has no threshold —
/// that is the real improvement — but `minimumRunMilliseconds` is one,
/// and at its 20 ms default it is about two render quanta wide. A player
/// that runs dry for a single quantum and recovers is invisible here,
/// and that is exactly the marginal regime the 800-vs-1600 ms decision
/// turned on.
///
/// It is kept, with its reason: below ~20 ms a zero run is as likely to
/// be a buffer boundary as a dropout, and counting boundaries as gaps
/// would make every clean recording look broken. But a reader comparing
/// two cushions near the margin should sweep this value the way §54
/// swept the amplitude floor — the honest lesson of that failure is that
/// ANY constant in a metric must be shown not to carry the result.
public enum DigitalSilence {

    public struct Report: Sendable, Equatable {
        /// Runs of exact silence found inside the speech span.
        public let runs: Int
        /// Their total length.
        public let totalMilliseconds: Double
        /// The longest single one — what an ear notices.
        public let longestMilliseconds: Double
        /// First non-zero sample to last, in milliseconds. Leading and
        /// trailing silence are NOT dropouts: the first is the cushion
        /// doing its job, the second is the reply having ended.
        public let spanMilliseconds: Double

        /// The comparable number: silence per second of speech. A rate,
        /// because a long reply has more chances to starve than a short
        /// one and the raw total would flatter the short one.
        public var millisecondsPerSecond: Double {
            spanMilliseconds > 0 ? totalMilliseconds / (spanMilliseconds / 1000) : 0
        }
    }

    /// Measures the dropouts in one captured reply.
    ///
    /// - Parameter minimumRunMilliseconds: runs shorter than this are
    ///   ignored. 20 ms by default — below that a zero run is a buffer
    ///   boundary or a genuine silent sample in the signal, not something
    ///   an ear hears as a gap.
    public static func measure(samples: [Float], sampleRate: Double,
                               minimumRunMilliseconds: Double = 20) -> Report {
        guard sampleRate > 0,
              let first = samples.firstIndex(where: { $0 != 0 }),
              let last = samples.lastIndex(where: { $0 != 0 })
        else { return Report(runs: 0, totalMilliseconds: 0,
                             longestMilliseconds: 0, spanMilliseconds: 0) }

        let msPerSample = 1000 / sampleRate
        // AT LEAST ONE SAMPLE. With a minimum of 0 the comparison
        // `current >= 0` is true at every non-zero sample, so the report
        // counted one "run" per sample of speech — a metric that answers
        // loudest when the audio is perfect.
        let minimumRun = max(1, Int((minimumRunMilliseconds / msPerSample).rounded(.up)))
        var runs = 0
        var total = 0
        var longest = 0
        var current = 0
        for index in first...last {
            if samples[index] == 0 {
                current += 1
                continue
            }
            if current >= minimumRun {
                runs += 1
                total += current
                longest = max(longest, current)
            }
            current = 0
        }
        // No trailing check: the span ENDS on a non-zero sample by
        // construction, so a run cannot be open here.
        return Report(runs: runs,
                      totalMilliseconds: Double(total) * msPerSample,
                      longestMilliseconds: Double(longest) * msPerSample,
                      spanMilliseconds: Double(last - first + 1) * msPerSample)
    }
}
