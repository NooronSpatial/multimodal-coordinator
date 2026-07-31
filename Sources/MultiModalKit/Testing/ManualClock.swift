import Synchronization

/// A hand-driven clock for deterministic tests (SPEC AC-9, AC-14).
///
/// Time stands still until a test calls `advance`. Code that sleeps on this
/// clock is parked — a bookmark (continuation) waits in a queue — and wakes
/// exactly at its deadline, seeing `now` equal to that deadline.
///
/// Design rules (each learned the hard way in an earlier project):
/// - One locked decision, then act OUTSIDE the lock. Never wake anyone while
///   holding the key: a woken sleeper often re-enters the clock immediately,
///   and the Mutex is not re-entrant.
/// - `advance` walks deadline by deadline (ties broken by arrival order) and
///   sets `now` to each deadline BEFORE waking, so woken code reads its own
///   scheduled moment and re-sleeps compute from the right base.
/// - Cancel and advance race for the same sleeper: removing the waiter from
///   the queue under the lock is the claim ticket — one claim, one resume.
/// - `waitForSleepers(atLeast:)` parks the TEST until sleeps are registered,
///   so tests never advance past a sleep that doesn't exist yet.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable, Hashable, CustomStringConvertible {
        public var offset: Duration

        public init(offset: Duration = .zero) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public var description: String { "t+\(offset)" }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Observer {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now = Instant()
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var observers: [Observer] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant {
        state.withLock { $0.now }
    }

    public var minimumResolution: Duration { .zero }

    /// Number of tasks currently parked in `sleep`.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id: UInt64 = state.withLock { s in
            defer { s.nextID += 1 }
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Decision {
                    case wakeNow
                    case alreadyCancelled
                    case parked([Observer])
                }
                let decision: Decision = state.withLock { s in
                    if Task.isCancelled {
                        return .alreadyCancelled           // the cancel handler ran before we parked
                    }
                    if deadline <= s.now {
                        return .wakeNow                    // no waiting for the past
                    }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    let satisfied = s.observers.filter { $0.threshold <= s.sleepers.count }
                    s.observers.removeAll { $0.threshold <= s.sleepers.count }
                    return .parked(satisfied)
                }
                switch decision {
                case .wakeNow:
                    continuation.resume()
                case .alreadyCancelled:
                    continuation.resume(throwing: CancellationError())
                case .parked(let satisfied):
                    for observer in satisfied {
                        observer.continuation.resume()
                    }
                }
            }
        } onCancel: {
            let claimed: Sleeper? = state.withLock { s in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)        // the claim ticket
            }
            claimed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Move time forward, waking every due sleeper in deadline order.
    public func advance(by duration: Duration) async {
        await advance(to: now.advanced(by: duration))
    }

    public func advance(to target: Instant) async {
        while true {
            enum Step {
                case wake(Sleeper)
                case done
            }
            let step: Step = state.withLock { s in
                precondition(target >= s.now, "ManualClock cannot move backwards")
                let due = s.sleepers
                    .filter { $0.deadline <= target }
                    .min { ($0.deadline.offset, $0.id) < ($1.deadline.offset, $1.id) }
                guard let next = due else {
                    s.now = target
                    return .done
                }
                s.now = max(s.now, next.deadline)          // the woken one sees its own moment
                s.sleepers.removeAll { $0.id == next.id }  // the claim ticket, advance's side
                return .wake(next)
            }
            switch step {
            case .done:
                await settle()
                return
            case .wake(let sleeper):
                sleeper.continuation.resume()
                await settle()
            }
        }
    }

    /// Park the TEST until at least `threshold` tasks are asleep here.
    /// Event-driven — resumed from sleep's own registration, never polled.
    public func waitForSleepers(atLeast threshold: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = state.withLock { s in
                if s.sleepers.count >= threshold {
                    return true
                }
                s.observers.append(Observer(threshold: threshold, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    /// A few cooperative yields so a freshly woken task can run (and maybe
    /// re-sleep) before the advance loop continues. Scheduler settling — the
    /// tests themselves never rely on it; they gate on events.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
