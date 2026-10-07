/// The latency seam (R2 ruling, 2026-08-12; the pattern proven in prior
/// private work): the coordinator captures instants at its own semantic
/// boundaries — inside the actor, sharing its isolation, so measurement
/// can never race the thing it measures — computes a `Duration`, and hands
/// it to whoever was injected. Tests assert exact values on a manual
/// clock; a console reporter prints; a future signpost reporter marks.
///
/// Injected as a PAIR with the clock: no reporter, no measurement, no
/// clock reads — the default coordinator stays fully clockless.
public protocol LatencyReporter: Sendable {
    /// Final transcript accepted → the synthesizer's own `started`
    /// evidence: the pause a user feels before the assistant is audible.
    func turnLatency(_ duration: Duration, turn: Int)

    /// Barge accepted (the ticket already raised, same actor step) → both
    /// stage cancels acknowledged by their seams. The turn number is the
    /// turn that DIED — the latency belongs to the interruption.
    func cancelLatency(_ duration: Duration, turn: Int)

    /// One spoken turn's pause, stage by stage (5d; D-133, F-25 A) —
    /// reported at the first sound, beside `turnLatency`, which equals its
    /// `sinceFinal`. The speech end inside it is the one instant stamped on
    /// arrival rather than inside the actor (D-134).
    ///
    /// Defaults to nothing, so a reporter written before 5d compiles
    /// unchanged — and so a reporter that WRAPS another must forward this
    /// and `bargeTimeline(_:)` itself, or the wrapped one never hears them.
    func turnTimeline(_ timeline: TurnTimeline)

    /// One interruption (5d; D-133): the barge window, then the silence —
    /// `cancelLatency` equals its `silence`. Defaults to nothing.
    func bargeTimeline(_ timeline: BargeTimeline)

    /// Every barge candidate, accepted or abandoned, as it was judged (5d
    /// piece 3, F-40 A): how long it stayed loud, its loudest chunk, its
    /// verdict. Defaults to nothing; a wrapping reporter must forward it.
    func bargeCandidate(_ candidate: BargeCandidate)
}

extension LatencyReporter {
    /// Nothing: a reporter that never asked for the timeline (5d, AC-340).
    public func turnTimeline(_ timeline: TurnTimeline) {}
    /// Nothing: a reporter that never asked for the timeline (5d, AC-340).
    public func bargeTimeline(_ timeline: BargeTimeline) {}
    /// Nothing: a reporter that never asked for candidates (5d piece 3).
    public func bargeCandidate(_ candidate: BargeCandidate) {}
}
