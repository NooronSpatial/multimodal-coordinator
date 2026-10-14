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
    /// How long the mind had already been thinking when the gate ran out —
    /// zero unless the reply was opened early, at the final (5d piece 4,
    /// F-46 A). It overlaps ③, so it is NOT part of `sinceFinal`: when it is
    /// non-zero, ③ ends at the gate's end and ④ is what was still left to
    /// wait for the first token there (zero when one was already held).
    public let thoughtInTheGate: Duration

    public init(turn: Int, earFinish: Duration?, gate: Duration,
                firstToken: Duration, firstSound: Duration,
                thoughtInTheGate: Duration = .zero) {
        self.turn = turn
        self.earFinish = earFinish
        self.gate = gate
        self.firstToken = firstToken
        self.firstSound = firstSound
        self.thoughtInTheGate = thoughtInTheGate
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
/// ONE BARGE CANDIDATE, AS IT WAS JUDGED (5d piece 3, F-40 A; AC-360).
///
///     onset ─▶ … loud · quiet · loud … ─▶ verdict: accepted (a LOUD chunk at or
///                                         after the deadline) or abandoned (its speech ended)
///
/// Reported for every candidate, accepted or not, so a session shows how
/// long a leak stays loud beside how long a person does — on the audio
/// timeline, the window's own.
public struct BargeCandidate: Sendable, Equatable {
    /// The speaking turn the candidate threatened.
    public let turn: Int
    /// Onset → the verdict: the deciding chunk's start, or the speech's end.
    public let window: Duration
    /// The loud chunks the candidate had shown when its verdict fell.
    public let loudTime: Duration
    /// Its loudest chunk, as RMS.
    public let peak: Float
    /// True: it cut the reply. False: its speech ended first.
    public let accepted: Bool

    public init(turn: Int, window: Duration, loudTime: Duration, peak: Float, accepted: Bool) {
        self.turn = turn
        self.window = window
        self.loudTime = loudTime
        self.peak = peak
        self.accepted = accepted
    }
}

/// ONE REPLY OPENED EARLY, inside the reply gate (5d piece 4, AC-368).
///
///     the final ─▶ the reply opened at once, its words HELD
///                    ├─ the gate runs out  ─▶ kept: the words go on
///                    └─ the person goes on ─▶ thrown away, in silence
///
/// Each thrown-away reply cost the device its thinking, and the mind its
/// kept session (D-144, F-44 A), so an app can see how often it happens.
public struct EarlyReply: Sendable, Equatable {
    /// The turn the reply was opened for.
    public let turn: Int
    /// True: the gate ran out and the reply went on. False: thrown away.
    public let kept: Bool
    /// The reply's open → the gate's end, or → the onset that threw it away.
    public let thought: Duration

    public init(turn: Int, kept: Bool, thought: Duration) {
        self.turn = turn
        self.kept = kept
        self.thought = thought
    }
}

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
