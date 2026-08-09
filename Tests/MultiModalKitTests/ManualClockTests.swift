import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

/// The clock itself, proven before anything depends on it (SPEC AC-14).
@Suite(.timeLimit(.minutes(1))) struct ManualClockTests {

    /// Tiny thread-safe recorder for observations from woken tasks.
    private final class Recorder<Value: Sendable>: Sendable {
        private let store = Mutex<[Value]>([])
        func append(_ value: Value) { store.withLock { $0.append(value) } }
        var values: [Value] { store.withLock { $0 } }
    }

    @Test func timeStandsStillUntilAdvanced() async {
        let clock = ManualClock()
        #expect(clock.now.offset == .zero)
        await clock.advance(by: .milliseconds(250))
        #expect(clock.now.offset == .milliseconds(250))
    }

    @Test func sleepingIntoThePastReturnsImmediately() async throws {
        let clock = ManualClock()
        await clock.advance(by: .milliseconds(10))
        try await clock.sleep(until: clock.now, tolerance: nil)
        try await clock.sleep(until: ManualClock.Instant(offset: .milliseconds(5)), tolerance: nil)
        #expect(clock.sleeperCount == 0)
    }

    @Test func sleeperWakesAtItsExactMoment() async throws {
        let clock = ManualClock()
        let wakes = Recorder<Duration>()
        let sleeper = Task {
            try await clock.sleep(for: .milliseconds(100), tolerance: nil)
            wakes.append(clock.now.offset)
        }
        await clock.waitForSleepers(atLeast: 1)
        await clock.advance(by: .milliseconds(99))
        #expect(wakes.values.isEmpty)                    // 99 is not 100
        await clock.advance(by: .milliseconds(1))
        try await sleeper.value
        #expect(wakes.values == [.milliseconds(100)])
    }

    @Test func earlierDeadlinesWakeFirstWithTheirOwnMoments() async throws {
        let clock = ManualClock()
        let order = Recorder<String>()
        let late = Task {
            try await clock.sleep(for: .milliseconds(20), tolerance: nil)
            order.append("late@\(clock.now.offset == .milliseconds(20))")
        }
        await clock.waitForSleepers(atLeast: 1)
        let early = Task {
            try await clock.sleep(for: .milliseconds(10), tolerance: nil)
            order.append("early@\(clock.now.offset == .milliseconds(10))")
        }
        await clock.waitForSleepers(atLeast: 2)
        await clock.advance(by: .milliseconds(30))
        try await early.value
        try await late.value
        #expect(order.values == ["early@true", "late@true"])
    }

    @Test func chainedSleepsLandExactlyInsideOneAdvance() async throws {
        let clock = ManualClock()
        let wakes = Recorder<Duration>()
        let sleeper = Task {
            try await clock.sleep(for: .milliseconds(10), tolerance: nil)
            wakes.append(clock.now.offset)
            try await clock.sleep(for: .milliseconds(10), tolerance: nil)
            wakes.append(clock.now.offset)
        }
        await clock.waitForSleepers(atLeast: 1)
        await clock.advance(by: .milliseconds(20))
        try await sleeper.value
        #expect(wakes.values == [.milliseconds(10), .milliseconds(20)])
    }

    @Test func cancellationClaimsTheSleeperExactlyOnce() async throws {
        let clock = ManualClock()
        let sleeper = Task {
            do {
                try await clock.sleep(for: .seconds(1), tolerance: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await clock.waitForSleepers(atLeast: 1)
        sleeper.cancel()
        #expect(await sleeper.value)
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: .seconds(2))             // must not double-wake (would trap)
    }

    @Test func sleepOnAnAlreadyCancelledTaskThrowsImmediately() async {
        let clock = ManualClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await clock.sleep(for: .seconds(1), tolerance: nil)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await sleeper.value)
        #expect(clock.sleeperCount == 0)
    }
}
