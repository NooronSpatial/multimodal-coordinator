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
/// zeros.** Speech never is exactly zero. So the signature needs no
/// threshold at all, and INSTRUMENTS §53 records it agreeing with Ryad's
/// ear on the two files he judged: 13 runs in the one he called hitchy,
/// none in the one he called better.
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
        let minimumRun = Int((minimumRunMilliseconds / msPerSample).rounded(.up))
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
