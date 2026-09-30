/// THE PAUSES INSIDE AN ANSWER (5d, ⑥; SPEC §225/2, F-27 A, AC-341).
///
///     sound  ███░░░░░░░░░███░░░░░███████░░░░░░░░░░░
///               └ 400 ms ┘   └200┘          └ the tail: never counted —
///                 a GAP     too short         the answer is over
///
/// Fed the samples a reply actually PLAYS, it counts the silent stretches
/// at least `minimumGap` long, and keeps the longest one of any length.
/// Pure and clockless, like `EnergyVAD`: samples in, facts out, and the
/// frame count is its only clock. A stretch counts only once sound CLOSES
/// it — silence before the first sound, and after the last, is not a
/// pause inside the answer.
public struct SilenceMeter: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// A sample quieter than this, in absolute value, is silent. The
        /// default 0.001 is −60 dBFS: a decoder's digital silence, not a
        /// soft syllable.
        public var level: Float
        /// The shortest silent stretch that counts as a gap. 300 ms sits
        /// above an ordinary pause between sentences (F-27 A).
        public var minimumGap: Duration
        /// The rate of the samples fed.
        public var sampleRate: Double

        public init(level: Float = 0.001, minimumGap: Duration = .milliseconds(300), sampleRate: Double) {
            self.level = level
            self.minimumGap = minimumGap
            self.sampleRate = sampleRate
        }
    }

    public let config: Config
    /// Closed silent stretches at least `minimumGap` long.
    public private(set) var gaps = 0
    /// The longest closed silent stretch, of any length, in frames.
    public private(set) var longestFrames = 0

    public init(config: Config) {
        self.config = config
    }

    /// Hears the next samples, in the order they played.
    public mutating func feed(_ samples: some Sequence<Float>) {
    }

    /// The longest closed silent stretch, as time.
    public var longest: Duration {
        .nanoseconds(Int64((Double(longestFrames) / config.sampleRate * 1e9).rounded()))
    }
}
