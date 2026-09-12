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

    @Test("a count already at the threshold returns at once; a rising count wakes the waiter")
    func wakesOnTheCount() async {
        let watch = ThresholdWatch()
        watch.set(2)
        #expect(await watch.wait(atLeast: 2))
        #expect(watch.count == 2)

        let waiter = Task { await watch.wait(atLeast: 4) }
        watch.increment()                       // 3: not yet
        watch.increment()                       // 4: now
        #expect(await Wait4y.fact { _ = await waiter.value }, "woken by the increment that met the threshold")
        #expect(await waiter.value)
    }

    @Test("a waiter whose task is cancelled returns false, at once — the cap can end a red test")
    func cancelReturnsFalse() async {
        let watch = ThresholdWatch()
        let parked = Task { await watch.wait(atLeast: 1) }
        // Cancel BEFORE and AFTER the park both end it: the claim ticket
        // is the same either way.
        parked.cancel()
        #expect(await Wait4y.fact { _ = await parked.value }, "a cancelled wait must not hang")
        #expect(await parked.value == false)
        #expect(watch.count == 0, "the count is untouched by a cancelled waiter")
        // And a later rise still wakes a live waiter — the cancelled
        // observer was removed, not left to be resumed twice.
        let live = Task { await watch.wait(atLeast: 1) }
        watch.increment()
        #expect(await live.value)
    }
}
