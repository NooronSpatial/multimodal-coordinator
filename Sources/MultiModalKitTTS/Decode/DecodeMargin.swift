// `DecodeMargin`: what one reply cost to decode — the per-reply
// measurement `NeuralVoice` reports and `AdaptiveLead` learns from.

/// WHAT ONE REPLY COST TO DECODE (AC-102/AC-104).
///
/// The Mac could read these off stderr. A phone cannot, and the phone is
/// where the question now lives: a field run reported the voice
/// "speaking in weird way like someone drunk", and the two leading
/// explanations — the decoder falling behind, or the audio playing at
/// the wrong rate — are told apart by numbers, not by adjectives.
public struct DecodeMargin: Sendable, Equatable {
    /// Audio produced, in milliseconds.
    public let audioMilliseconds: Double
    /// Wall time from the run's birth to its last decode step.
    public let wallMilliseconds: Double
    /// The first step's cost, paid once per reply.
    public let prefillMilliseconds: Double
    /// Decode wall time ÷ audio produced, measured from the FIRST step
    /// onward so the fixed prefill is not smeared across it. This is the
    /// number that says whether the machine can stream this voice.
    public let steadyRealTimeFactor: Double

    /// Below 1.0 the decoder runs ahead of the ear. At or above it, the
    /// player will run dry unless a lead was banked first.
    public var keepsUp: Bool { steadyRealTimeFactor < 1.0 }
    /// Whether the run FINISHED. A failed decode reports its margin too —
    /// the numbers are real — but its `audioMilliseconds` is however much
    /// audio existed when the throw happened, not a reply the conversation
    /// produced. The 4m review proved the consequence: an error-truncated
    /// length teaching the window that "replies are short" biases the
    /// cushion in exactly the under-banked direction 4m exists to fix.
    public let completed: Bool
    /// The cushion that was IN FORCE for this reply — the lead the run was
    /// BUILT with, stamped by the run itself. The 4n review proved why the
    /// consumer cannot ask the voice instead: the learner adapts from this
    /// very margin BEFORE any listener runs, so `currentLead` read in a
    /// margin handler is already the NEXT reply's cushion. On the exact
    /// session-start row §50 wants to convict, that misread logged a fat
    /// healthy cushion onto the one turn that ran starved. `nil` only for
    /// margins built outside a run (tests).
    public let cushionMilliseconds: Double?

    /// THE CUSHION THIS REPLY TURNED OUT TO NEED (4o, AC-176, D-080).
    ///
    /// The audio that had to be banked before playback started, computed
    /// from this reply's own decode steps by `DecodeDeficit.cushion`. It
    /// is an amount of AUDIO, not a wall time — the distinction the
    /// review caught, and the reason a faster-than-real-time decoder was
    /// previously under-banked.
    /// This is what sizes the next cushion, and it replaces
    /// `replyLength × (steadyRealTimeFactor − 1)`, which INSTRUMENTS §53
    /// measured predicting 1248 ms where 5593 ms of silence occurred.
    ///
    /// `nil` when no per-step record existed — margins built by hand in
    /// tests, and any decoder that reports no steps.
    public let requiredCushionMilliseconds: Double?

    init(audioMilliseconds: Double, wallMilliseconds: Double,
         prefillMilliseconds: Double, steadyRealTimeFactor: Double,
         completed: Bool = true, cushionMilliseconds: Double? = nil,
         requiredCushionMilliseconds: Double? = nil) {
        self.requiredCushionMilliseconds = requiredCushionMilliseconds
        self.audioMilliseconds = audioMilliseconds
        self.wallMilliseconds = wallMilliseconds
        self.prefillMilliseconds = prefillMilliseconds
        self.steadyRealTimeFactor = steadyRealTimeFactor
        self.completed = completed
        self.cushionMilliseconds = cushionMilliseconds
    }
}
