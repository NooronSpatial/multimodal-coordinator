/// Energy-based voice activity detection, v1 (SPEC AC-11).
///
/// The simplest honest judge: a chunk is "loud" when its RMS energy crosses
/// a threshold. Speech starts on the first loud chunk. Speech ends only
/// after a HANGOVER of quiet — a budget of quiet frames that keeps speech
/// "on" through the small gaps between words, so a sentence doesn't
/// shatter into pieces.
///
/// Deliberately pure: no clock, no tasks, no allocation. The hangover is
/// counted in FRAMES, not seconds — at 48 kHz, 14,400 frames = 300 ms.
/// Frame counts make the component fully deterministic with no time source,
/// and the caller (who knows the sample rate) does the one conversion.
///
/// Granularity: the verdict is per CHUNK (one RMS per call). With ~10 ms
/// chunks that is plenty for turn-taking; per-sample precision belongs to a
/// smarter VAD in a later phase (documented in D-008).
public struct EnergyVAD: VoiceActivityDetecting {
    public struct Config: Sendable {
        /// RMS level a chunk must reach to count as loud. Normal speech on
        /// a laptop microphone lands well above 0.02; room noise below it.
        public var threshold: Float
        /// Quiet frames allowed before speech is declared over.
        public var hangoverFrames: Int
        /// Loud frames required before speech is declared started — the
        /// hangover's mirror (D-035). 0 = off: the first loud chunk fires,
        /// byte-for-byte the pre-1d behavior. The caller who sets this must
        /// also wire the pump's pre-roll to cover it (the F-4 wiring law),
        /// or the window's own chunks — the start of the word — fall off
        /// the pre-roll shelf.
        public var onsetFrames: Int

        public init(
            threshold: Float = 0.02,
            hangoverFrames: Int = 14_400,
            onsetFrames: Int = 0
        ) {
            self.threshold = threshold
            self.hangoverFrames = hangoverFrames
            self.onsetFrames = onsetFrames
        }
    }

    /// The transition type now lives at the seam (D-022).
    public typealias Transition = SpeechTransition

    private let config: Config
    private var isSpeaking = false
    private var quietFrames = 0
    /// Consecutive loud frames heard while quiet — the onset candidate
    /// (D-035). One quiet chunk resets it (F-2); it plays no role while
    /// speaking.
    private var loudFrames = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Judge one chunk. Returns a transition when the state flips,
    /// nil when nothing changes. At most one transition per chunk.
    public mutating func process(_ chunk: UnsafeBufferPointer<Float>) -> SpeechTransition? {
        guard let base = chunk.baseAddress, chunk.count > 0 else { return nil }

        var sumOfSquares: Float = 0
        for index in 0..<chunk.count {
            let sample = base[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(chunk.count)).squareRoot()

        if rms >= config.threshold {                     // a loud chunk
            quietFrames = 0                              // the hangover resets
            if !isSpeaking {
                loudFrames += chunk.count                // the candidate grows
                if loudFrames >= config.onsetFrames {    // the window is filled
                    isSpeaking = true                    // (0 fills at once)
                    loudFrames = 0
                    return .speechStarted
                }
            }
            return nil
        }

        // a quiet chunk
        loudFrames = 0                                   // the candidate dies (F-2)
        guard isSpeaking else { return nil }             // quiet while quiet: nothing
        quietFrames += chunk.count
        if quietFrames >= config.hangoverFrames {        // the budget is spent
            isSpeaking = false
            quietFrames = 0
            return .speechEnded
        }
        return nil                                       // still inside the hangover
    }

    /// Convenience for cool-side callers and tests.
    public mutating func process(_ chunk: [Float]) -> Transition? {
        chunk.withUnsafeBufferPointer { process($0) }
    }
}
