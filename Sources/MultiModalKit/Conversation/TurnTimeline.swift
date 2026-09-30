/// ONE SPOKEN TURN'S PAUSE, stage by stage (5d; SPEC §224–§227, D-133).
///
///     the person's sound stops
///       │ ① the app's VAD hangover — its own policy, known exactly (F-26 A)
///       ▼
///     the speech-end decision        AudioEvent.speechEnded, stamped on arrival (D-134)
///       │ ② earFinish
///       ▼
///     the final transcript           where `turnLatency` starts
///       │ ③ gate
///       ▼
///     the reply opened
///       │ ④ firstToken
///       ▼
///     the first token
///       │ ⑤ firstSound
///       ▼
///     the FIRST SOUND                SynthesisUpdate.started — reported here
///
/// Reported at the first sound (D-133): the pause is over there, so a reply
/// the person cuts short afterwards still counts.
public struct TurnTimeline: Sendable, Equatable {
    /// The turn this pause belongs to.
    public let turn: Int
    /// ② The speech-end decision → the final transcript. Negative when the
    /// ear finished before the decision; `nil` when the coordinator never
    /// saw this utterance's end.
    public let earFinish: Duration?
    /// ③ The final transcript → the reply opened: the reply gate (AC-81),
    /// zero without one.
    public let gate: Duration
    /// ④ The reply opened → its first token.
    public let firstToken: Duration
    /// ⑤ The first token → the first sound.
    public let firstSound: Duration

    public init(turn: Int, earFinish: Duration?, gate: Duration,
                firstToken: Duration, firstSound: Duration) {
        self.turn = turn
        self.earFinish = earFinish
        self.gate = gate
        self.firstToken = firstToken
        self.firstSound = firstSound
    }

    /// ③ + ④ + ⑤ — exactly what `LatencyReporter.turnLatency` reports
    /// (AC-337).
    public var sinceFinal: Duration { gate + firstToken + firstSound }

    /// The pause the person feels, from their last sound to the reply's
    /// first: the app's own `hangover` (①), then ② to ⑤ (F-26 A). `nil`
    /// when the speech end was not seen.
    public func felt(hangover: Duration) -> Duration? {
        earFinish.map { hangover + $0 + sinceFinal }
    }
}

/// ONE INTERRUPTION, stage by stage (5d; SPEC §227 AC-338, D-133).
///
///     the person's first sound over the reply
///       │ ⑦ window — on the audio timeline the window is defined on (D-071)
///       ▼
///     the barge accepted             where `cancelLatency` starts
///       │ ⑧ silence
///       ▼
///     both stages acknowledged their cancel
public struct BargeTimeline: Sendable, Equatable {
    /// The turn that died.
    public let turn: Int
    /// ⑦ The person's first sound → the barge accepted. Zero when the
    /// window is off, or when the reply had not started speaking yet.
    public let window: Duration
    /// ⑧ The barge accepted → both stages acknowledged their cancel: what
    /// `cancelLatency` reports.
    public let silence: Duration

    public init(turn: Int, window: Duration, silence: Duration) {
        self.turn = turn
        self.window = window
        self.silence = silence
    }
}
