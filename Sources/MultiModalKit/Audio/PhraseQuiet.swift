/// THE QUIET AROUND A PHRASE (5d piece 2; SPEC §235/1, F-32 A, F-33 A, AC-348).
///
///     what the voice made:  ░░░░░░░░[ the words ]░░░░░░░░░░░
///                           ~325 ms               ~420 ms        (Kokoro, INSTRUMENTS §73b)
///     what is kept:            ░░[ the words ]░░░░
///                          margin              the closing mark's pause
///
/// A one-shot voice wraps every phrase in quiet of its own, so two phrases
/// back to back leave ~0.75 s of silence at EVERY boundary — at a comma, at
/// a full stop, and at a cap cut in the middle of a clause. This rule finds
/// the words by the audio, at the meter's level, and says which samples to
/// keep: `margin` before the first loud sample (a soft "h" or "s" starts
/// below the level, and the margin keeps it), and after the last one the
/// pause the phrase's closing mark calls for — `margin` again when the
/// phrase ends on no mark the table knows (a cap cut).
///
/// Pure and clockless, like `SilenceMeter`: samples in, a range out. It
/// only ever shortens the two EDGES — the quiet inside the words is the
/// voice's own phrasing and stays — and it never removes a loud sample.
public struct PhraseQuiet: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// A sample quieter than this, in absolute value, is quiet: the
        /// meter's level (`SilenceMeter.Config.level`), so the trim and the
        /// meter can never disagree about where the words are.
        public var level: Float
        /// Kept before the first loud sample, and after the last one when
        /// the phrase ends on no mark in `pauses`.
        public var margin: Duration
        /// Kept after the last loud sample, by the phrase's closing mark.
        /// What the person hears at a boundary is this, plus the next
        /// phrase's `margin`.
        public var pauses: [Character: Duration]

        public init(level: Float = 0.001, margin: Duration, pauses: [Character: Duration]) {
            self.level = level
            self.margin = margin
            self.pauses = pauses
        }
    }

    public let config: Config

    public init(config: Config) {
        self.config = config
    }

    /// The range of `samples` to keep, for a phrase that closed on
    /// `closingMark` (nil: it closed on none — a cap cut, or a reply's end
    /// without one).
    public func kept(_ samples: [Float], closingMark: Character?, sampleRate: Double) -> Range<Int> {
        guard let first = samples.firstIndex(where: { abs($0) >= config.level }),
              let last = samples.lastIndex(where: { abs($0) >= config.level }) else {
            return 0..<samples.count        // nothing loud: no words to find, nothing to cut
        }
        let margin = Self.frames(config.margin, at: sampleRate)
        let pause = closingMark.flatMap { config.pauses[$0] }.map { Self.frames($0, at: sampleRate) } ?? margin
        return max(0, first - margin)..<min(samples.count, last + 1 + pause)
    }

    private static func frames(_ duration: Duration, at rate: Double) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(((Double(seconds) + Double(attoseconds) * 1e-18) * rate).rounded())
    }

    /// The clause mark a phrase closes on: its last character that is not
    /// whitespace, if that is one of the marks the phraser cuts at.
    public static func closingMark(of phrase: String) -> Character? {
        guard let last = phrase.last(where: { !$0.isWhitespace }),
              SpeechPhraser.clauseMarks.contains(last) else { return nil }
        return last
    }
}
