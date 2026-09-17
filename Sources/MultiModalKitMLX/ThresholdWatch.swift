// A COUNT A TEST CAN WAIT ON, AND BE CANCELLED WHILE WAITING (4y, the
// review of the mlx piece).
//
// Two facts this milestone's rows need are counts that rise on the
// model's own steps: how many admissions are PARKED at the gate (AC-258's
// two-caller row must know the second caller is at the gate before it
// lets the first's load end), and how many generations have BEGUN (a
// generation begins one hop after `openReply` returns, so "none in
// flight" is also true of one that has not started — `waitForIdle()`'s
// note). Both are waited on by a test RACED AGAINST A CAP, and a wait
// the cap cannot cancel is a hang, not a red: a task group returns only
// when every child has, and a `withCheckedContinuation` with nobody to
// resume it never does. The first cut of these hooks parked on exactly
// that and the mutant run hung for ten minutes. This is
// `ManualClock.waitForSleepers`'s shape, kept: a `Mutex`, an observer
// with a claim ticket, resumed by the count reaching the threshold OR by
// the cancel handler — whichever claims it first, under the lock.

import Synchronization

/// A monotonic-or-set count with observers that wait for a threshold.
/// Nonisolated on purpose: the actors that own the counts call `set` and
/// `increment` from their own steps (synchronously, no hop), and a test
/// calls `wait` from any task.
final class ThresholdWatch: Sendable {
    private struct Observer {
        let id: UInt64
        let threshold: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var count = 0
        var nextID: UInt64 = 0
        var observers: [Observer] = []
    }

    private let state = Mutex(State())

    /// The count as of now.
    var count: Int { state.withLock { $0.count } }

    /// Sets the count and wakes every observer whose threshold it meets.
    /// Observers are taken under the lock and resumed OUTSIDE it (lock
    /// rule 2): whoever is waiting is a test's task, and nothing of ours
    /// holds a lock while somebody else's code runs.
    func set(_ count: Int) {
        let due = state.withLock { state -> [Observer] in
            state.count = count
            let met = state.observers.filter { $0.threshold <= count }
            state.observers.removeAll { $0.threshold <= count }
            return met
        }
        for observer in due { observer.continuation.resume(returning: true) }
    }

    /// One more, in one locked step.
    func increment() {
        let due = state.withLock { state -> [Observer] in
            state.count += 1
            let count = state.count
            let met = state.observers.filter { $0.threshold <= count }
            state.observers.removeAll { $0.threshold <= count }
            return met
        }
        for observer in due { observer.continuation.resume(returning: true) }
    }

    /// Parks until the count is at least `threshold`. Returns `true` when
    /// it is, `false` when the waiting task was cancelled first — so a
    /// caller racing it against a cap can tell the two apart. Cancel and
    /// registration race for the same observer: removing it under the
    /// lock is the claim ticket.
    @discardableResult
    func wait(atLeast threshold: Int) async -> Bool {
        let id: UInt64 = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enum Decision {
                    case ready
                    case alreadyCancelled
                    case parked
                }
                let decision: Decision = state.withLock { state in
                    if Task.isCancelled { return .alreadyCancelled }   // the cancel handler ran first
                    if state.count >= threshold { return .ready }
                    state.observers.append(
                        Observer(id: id, threshold: threshold, continuation: continuation))
                    return .parked
                }
                switch decision {
                case .ready: continuation.resume(returning: true)
                case .alreadyCancelled: continuation.resume(returning: false)
                case .parked: break
                }
            }
        } onCancel: {
            let claimed: Observer? = state.withLock { state in
                guard let index = state.observers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.observers.remove(at: index)       // the claim ticket
            }
            claimed?.continuation.resume(returning: false)
        }
    }
}
