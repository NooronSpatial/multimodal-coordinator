import Synchronization

/// A one-way switch that tasks can wait on (D-014).
///
/// It starts off. `signal()` turns it on, forever. Anyone waiting is woken;
/// anyone who waits afterwards returns immediately. That "afterwards" case is
/// the whole reason this type exists — a flag you can only read when you wake
/// up is useless to a task that is already asleep.
///
/// Two familiar rules are respected here:
///
/// - **Never resume a continuation while holding the lock.** Snapshot the
///   waiters under the lock, resume them outside. A resumed task can run
///   immediately and call back in — and that is a silent deadlock.
/// - **A waiter is claimed exactly once.** Cancellation and `signal()` can
///   arrive at the same moment from different threads. Whoever removes the
///   waiter from the table owns it and resumes it; the loser finds nothing and
///   does nothing. Same ticket idea as the clock's sleepers.
public final class StopSignal: Sendable {
    private struct State {
        var isOn = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Has the switch been turned on?
    public var isOn: Bool { state.withLock { $0.isOn } }

    /// Turns it on and wakes everyone waiting. Safe to call many times.
    public func signal() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOn = true
            let all = Array(state.waiters.values)
            state.waiters.removeAll()
            return all
        }
        for waiter in waiting { waiter.resume() }   // outside the lock, always
    }

    /// Waits until the switch is on. Returns at once if it already is, and
    /// also returns if the waiting task is cancelled — a waiter must never be
    /// left parked forever.
    public func wait() async {
        if isOn { return }

        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            return id
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyOn = state.withLock { state -> Bool in
                    if state.isOn { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if alreadyOn { continuation.resume() }   // outside the lock
            }
        } onCancel: {
            // Claim the ticket: if it is still there, it is ours to resume.
            let claimed = state.withLock { $0.waiters.removeValue(forKey: id) }
            claimed?.resume()
        }
    }
}
