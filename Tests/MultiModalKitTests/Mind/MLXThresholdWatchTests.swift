import Foundation
import Testing
@testable import MultiModalKitMLX

// THE COUNT A TEST WAITS ON (4y, the review of the mlx piece): the hook
// behind `MindAdmission.parked` and `LocalMindModel.generationsBegun`.
// Two promises, both about a RED test: it wakes on the count, and it
// lets a cap cancel it — the first cut parked on a plain continuation
// and the mutant run hung for ten minutes instead of dying in ten
// seconds.

@Suite("ThresholdWatch · wakes on the count, and lets a cap cancel it", .timeLimit(.minutes(1)))
struct MLXThresholdWatchTests {

    /// THE ROWS THAT PIN A CANCELLABLE WAIT MUST THEMSELVES BE CANCELLABLE.
    /// The first version of both rows awaited `Task.value` bare, or wrapped
    /// it in a group child — and `Task.value` ignores cancellation, so under
    /// a watch that never fires they HUNG past the suite's limit and the
    /// test process never exited (the re-attack of this piece had to kill
    /// it by hand). Every wait below races the TASK through `settled`, which
    /// cancels it on the cap, and the watch honours that cancellation. Under
    /// the same mutant these rows now die in 10 and 21 seconds.
    @Test("a count already at the threshold returns at once; a rising count wakes the waiter")
    func wakesOnTheCount() async throws {
        let watch = ThresholdWatch()
        watch.set(2)
        #expect(try await Wait4y.settled(Task { await watch.wait(atLeast: 2) }))
        #expect(watch.count == 2)

        let waiter = Task<Bool, any Error> { await watch.wait(atLeast: 4) }
        watch.increment()                       // 3: not yet
        watch.increment()                       // 4: now
        #expect(try await Wait4y.settled(waiter), "woken by the increment that met the threshold")
    }

    @Test("a waiter whose task is cancelled returns false, at once — the cap can end a red test")
    func cancelReturnsFalse() async throws {
        let watch = ThresholdWatch()
        let parked = Task<Bool, any Error> { await watch.wait(atLeast: 1) }
        // Cancel BEFORE and AFTER the park both end it: the claim ticket
        // is the same either way.
        parked.cancel()
        #expect(try await Wait4y.settled(parked) == false, "a cancelled wait returns false, and must not hang")
        #expect(watch.count == 0, "the count is untouched by a cancelled waiter")
        // And a later rise still wakes a live waiter — the cancelled
        // observer was removed, not left to be resumed twice.
        let live = Task<Bool, any Error> { await watch.wait(atLeast: 1) }
        watch.increment()
        #expect(try await Wait4y.settled(live))
    }
}
