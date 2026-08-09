/// The seam for "is this speech?" (D-022, F-a).
///
/// The pump judges chunks through THIS — `EnergyVAD` today, an adaptive or
/// model-based detector tomorrow — without the pump's signature changing.
/// Found in the 2a audit: D-018 ruled that the boundaries are OURS, but the
/// pump named a concrete type, which made the ruling true in prose and false
/// in code.
public enum SpeechTransition: Sendable, Equatable {
    case speechStarted
    case speechEnded
}

public protocol VoiceActivityDetecting: Sendable {
    /// Judge one chunk. Return a transition when the state flips,
    /// nil when nothing changes. At most one transition per chunk.
    mutating func process(_ chunk: UnsafeBufferPointer<Float>) -> SpeechTransition?
}
