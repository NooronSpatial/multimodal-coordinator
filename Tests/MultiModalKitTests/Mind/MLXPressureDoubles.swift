import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE DOUBLES 4y'S MLX ROWS SHARE (SPEC §187, AC-258..AC-264).
//
// Three suites and the live rows need the same hands: a pressure source
// the test pushes, a gate a scripted load parks on, and the two waits
// this repo insists on — an EVENT raced against a SLEEPING cap, so a red
// test dies in seconds and a green one never sleeps for luck.

/// The kernel's pressure, as a hand: `push(_:)` delivers a level to the
/// mind's handler the way the dispatch source would — synchronously, on
/// the caller's thread — and records whether the mind ever let go.
final class ScriptedPressureSource: MemoryPressureSourcing, Sendable {
    private struct State {
        var handler: (@Sendable (MemoryPressureMonitor.Level) -> Void)?
        var subscriptions = 0
        var cancellations = 0
    }
    private let state = Mutex(State())

    func subscribe(
        onChange: @escaping @Sendable (MemoryPressureMonitor.Level) -> Void
    ) -> MemoryPressureSubscription {
        state.withLock {
            $0.handler = onChange
            $0.subscriptions += 1
        }
        // `self`, not `[state]`: a `Mutex` is non-copyable and cannot be
        // captured by value, and a source outlives every subscription it
        // hands out in these tests.
        return MemoryPressureSubscription {
            self.state.withLock {
                $0.handler = nil
                $0.cancellations += 1
            }
        }
    }

    /// The kernel speaks. Taken under the lock, CALLED outside it — the
    /// handler hops to an actor, and nothing of ours holds a lock while
    /// somebody else's code runs.
    func push(_ level: MemoryPressureMonitor.Level) {
        let handler = state.withLock { $0.handler }
        handler?(level)
    }

    var subscriptions: Int { state.withLock { $0.subscriptions } }
    var cancellations: Int { state.withLock { $0.cancellations } }
}

/// A door a scripted load parks behind until the test opens it — one
/// continuation, one claim ticket, resumed outside the lock, and honest
/// under cancellation (a parked task that is cancelled is let go, so a
/// red test's cap can end it).
final class TestGate: Sendable {
    private struct State {
        var open = false
        var parked: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    /// Opens the door, waking whoever is parked. Idempotent.
    func open() {
        let woken = state.withLock { gate -> CheckedContinuation<Void, Never>? in
            gate.open = true
            defer { gate.parked = nil }
            return gate.parked
        }
        woken?.resume()
    }

    /// Parks until the door is open, or until this task is cancelled.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { gate -> Bool in
                    if gate.open || Task.isCancelled { return true }
                    gate.parked = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let claimed = state.withLock { gate -> CheckedContinuation<Void, Never>? in
                defer { gate.parked = nil }
                return gate.parked
            }
            claimed?.resume()
        }
    }
}

/// Named facts, sent by the code under test's hands and awaited by the
/// test — the `AdmissionTests` shape, kept so no row here waits on time.
final class Facts: Sendable {
    private let stream: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation
    private let seen = Mutex<[String]>([])

    init() {
        (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    func send(_ name: String) {
        seen.withLock { $0.append(name) }
        emit.yield(name)
    }

    /// Everything sent so far, in order.
    var log: [String] { seen.withLock { $0 } }

    /// Waits for `name` to have been sent, raced against a sleeping cap.
    /// Reads the log FIRST, so a fact sent before the wait began is not
    /// missed — the stream is one listener's, and this may not be the
    /// first call.
    func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
        if seen.withLock({ $0.contains(name) }) { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await event in stream where event == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// The two waits every 4y row uses.
enum Wait4y {
    /// Races a task's value against a sleeping cap; the loser is
    /// cancelled. `Task.value` itself cannot be cancelled, hence the race.
    static func settled<T: Sendable>(_ task: Task<T, any Error>,
                                     within deadline: Duration = .seconds(10)) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw Wait4yTimedOut(after: deadline)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Races an async fact against a sleeping cap: `true` when the fact
    /// arrived first. The fact's task is cancelled when the cap wins.
    static func fact(within deadline: Duration = .seconds(10),
                     _ body: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await body()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Waits for a `ManualClock` to have a sleeper parked — the clock's
    /// own event, raced against a cap (the piece-1 `parked` helper).
    static func parked(_ clock: ManualClock, atLeast count: Int = 1,
                       within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await clock.waitForSleepers(atLeast: count) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Waits for the model's actor to have HANDLED `level` — the fact
    /// `pressure(_:)` yields on its way out (AC-262's event, never a poll).
    static func handled(_ level: MemoryPressureMonitor.Level, on model: LocalMindModel,
                        within deadline: Duration = .seconds(10)) async -> Bool {
        await fact(within: deadline) {
            for await seen in model.pressureLevels where seen == level { return }
        }
    }
}

/// Named for its file: `AdmissionTests` and `ReplyContractTests` each keep
/// a private twin, and two internal ones in one module collide.
struct Wait4yTimedOut: Error, CustomStringConvertible {
    let after: Duration
    var description: String { "the task did not settle within \(after)" }
}

/// Collects a run's updates until its stream ends — the whole story of
/// one reply, and `Facts` for the tokens as they land, so a test can act
/// AFTER the second token rather than after a guess.
enum ReplyStory {
    static func collect(_ run: any ReplyRun, facts: Facts) -> Task<[ReplyUpdate], any Error> {
        Task {
            var story: [ReplyUpdate] = []
            for await update in run.updates {
                story.append(update)
                if case .token = update { facts.send("token \(story.count)") }
            }
            facts.send("ended")
            return story
        }
    }
}
