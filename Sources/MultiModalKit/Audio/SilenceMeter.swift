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
    /// THE QUIET BEFORE THE FIRST WORD (5d piece 2; F-35 A, AC-351), in
    /// frames: what the person waits through after the player starts. Nil
    /// until the first sound — a reply that never sounds has no first word.
    public private(set) var leadingFrames: Int?

    /// The silent stretch still open — closed by the next sound.
    private var run = 0
    /// Silence before the first sound is the reply not yet begun.
    private var heardSound = false
    /// Quiet frames heard before the first sound, while it is awaited.
    private var quietBefore = 0
    /// `minimumGap` in frames.
    private let gapFrames: Int

    public init(config: Config) {
        self.config = config
        let (seconds, attoseconds) = config.minimumGap.components
        gapFrames = Int(((Double(seconds) + Double(attoseconds) * 1e-18) * config.sampleRate).rounded())
    }

    /// Hears the next samples, in the order they played.
    public mutating func feed(_ samples: some Sequence<Float>) {
        for sample in samples {
            if abs(sample) < config.level {
                if heardSound { run += 1 } else { quietBefore += 1 }
            } else {
                if run > 0 { close() }
                if !heardSound { leadingFrames = quietBefore }
                heardSound = true
            }
        }
    }

    /// Sound after a silent stretch: the stretch was a pause.
    private mutating func close() {
        if run >= gapFrames { gaps += 1 }
        longestFrames = max(longestFrames, run)
        run = 0
    }

    /// The longest closed silent stretch, as time.
    public var longest: Duration {
        .nanoseconds(Int64((Double(longestFrames) / config.sampleRate * 1e9).rounded()))
    }

    /// The quiet before the first sound, as time — nil before any sound.
    public var leading: Duration? {
        leadingFrames.map { .nanoseconds(Int64((Double($0) / config.sampleRate * 1e9).rounded())) }
    }
}
