/// A moment in the audio's OWN time (SPEC AC-13, D-011).
///
/// Not a wall clock, not the scheduler's clock: just how many frames of sound
/// have passed since capture began, divided by the sample rate. Two machines
/// under different load produce the same `AudioTime` for the same sound —
/// which is why latency can be an exact number in tests instead of a
/// measurement.
public struct AudioTime: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Frames of audio that passed before this moment.
    public let frames: Int
    /// Frames per second of the stream this moment belongs to.
    public let sampleRate: Double

    public init(frames: Int, sampleRate: Double) {
        self.frames = frames
        self.sampleRate = sampleRate
    }

    /// The same moment expressed in seconds.
    public var seconds: Double { Double(frames) / sampleRate }

    public static func < (lhs: AudioTime, rhs: AudioTime) -> Bool {
        lhs.frames < rhs.frames
    }

    public var description: String { "\(frames)f" }
}

/// One fixed-size piece of sound, with the moment it began (SPEC AC-17).
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let start: AudioTime

    public init(samples: [Float], start: AudioTime) {
        self.samples = samples
        self.start = start
    }

    public var frameCount: Int { samples.count }
}

/// Everything the pump can tell the world, in timeline order (SPEC AC-12).
///
/// `dropped` is here on purpose (D-010): when the machine falls behind, the
/// loss appears at the exact point where it happened, instead of hiding in a
/// counter somebody has to remember to read.
public enum AudioEvent: Sendable, Equatable {
    /// Speech began. `utterance` is the utterance's IDENTITY, assigned HERE
    /// at the source (D-034): every consumer reads the same number from the
    /// same event, so no two components ever count in parallel — parallel
    /// counters over drop-tolerant streams desync forever (the review's
    /// mirror finding). The number travels WITH the evidence it names.
    case speechStarted(utterance: Int, at: AudioTime)
    case audioSegment(AudioChunk)
    case speechEnded(at: AudioTime)
    case dropped(frames: Int, at: AudioTime)
}
