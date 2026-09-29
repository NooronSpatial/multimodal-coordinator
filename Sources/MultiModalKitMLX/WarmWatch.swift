// THE WARM'S END, AS AN EVENT (5b, AC-312; D-116 F-7 A, D-124 F-21 B).
//
// RED skeleton: the shape without the judgment. Every rule is a failing
// test until GREEN wires it.

import Synchronization

/// Watches one model's warm and answers `whenWarm()`.
final class WarmWatch: Sendable {
    /// Every waiter that registered, ever — the EVENT a test waits on
    /// before it ends a load, never a guess about time.
    let waitersSeen = ThresholdWatch()

    func asked() {}
    func askEnded() {}
    func loadBegan() {}
    func loadEnded(resident: Bool) {}
    func retired() {}

    /// Whether a warm is asked for or a load is in flight.
    var isWarming: Bool { false }

    func whenWarm() async -> Bool { false }
}
