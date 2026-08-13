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
}
