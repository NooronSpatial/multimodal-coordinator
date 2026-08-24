import Foundation
import MultiModalKit
import Synchronization
import Testing

/// `Retirable` is the fifth attempt at a shape this project has got wrong
/// four times (D-051), so it is tested the way the fifth attempt deserves:
/// every test gates on an EVENT, none on a delay, and each one fails fast
/// rather than hanging.
@Suite("a retirable resource")
struct RetirableTests {

    /// A one-shot event. The tests need "the build has started" and "let the
    /// build finish" as facts, never as timings — CLAUDE.md §3.3.
    final class Latch: Sendable {
        private struct Guarded {
            var fired = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(Guarded())

        func fire() {
            // Snapshot under the lock, resume OUTSIDE it: resuming a
            // continuation while holding a lock is the rule that once killed
            // a process in this project (§4.1, lock rule 2).
            let waking = state.withLock { guarded -> [CheckedContinuation<Void, Never>] in
                guarded.fired = true
                let all = guarded.waiters
                guarded.waiters = []
                return all
            }
            for waiter in waking { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let alreadyFired = state.withLock { guarded -> Bool in
                    if guarded.fired { return true }
                    guarded.waiters.append(continuation)
                    return false
                }
                if alreadyFired { continuation.resume() }
            }
        }
    }

    /// Counts builds and discards without an actor hop.
    final class Ledger: Sendable {
        let builds = Mutex(0)
        let discarded = Mutex([Int]())
        func nextBuild() -> Int { builds.withLock { $0 += 1; return $0 } }
    }

    // MARK: built once

    @Test("two callers arriving together get one build, and the same value")
    func oneBuildForConcurrentCallers() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        let started = Latch(), release = Latch()

        async let first = holder.value {
            started.fire()
            await release.wait()
            return ledger.nextBuild()
        }
        await started.wait()                       // the first build is IN FLIGHT
        async let second = holder.value { ledger.nextBuild() }
        release.fire()

        let values = try await [first, second]
        #expect(values == [1, 1], "the second caller must be handed the first's value")
        #expect(ledger.builds.withLock { $0 } == 1)
    }

    @Test("a second call after the first finished does not rebuild")
    func cachedAfterwards() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        _ = try await holder.value { ledger.nextBuild() }
        _ = try await holder.value { ledger.nextBuild() }
        #expect(ledger.builds.withLock { $0 } == 1)
        #expect(await holder.isResident)
    }

    /// THE STRANDED WAITER — three callers, not two.
    ///
    /// Every other test in this suite uses the builder plus ONE waiter, and
    /// that is precisely the case the bug could not reach: the builder woke
    /// one waiter, that waiter found the value and returned, and there was
    /// nobody left to strand. With a THIRD caller the chain broke and this
    /// test did not fail — it HUNG, and had to be killed by a timeout.
    ///
    /// Written after the fact, from a suspicion raised while reviewing the
    /// very code that shipped it. The lesson is not "wake everyone"; it is
    /// that **two is not a concurrency test**.
    @Test("THREE concurrent cold callers all get the value — none is stranded")
    func threeCallersNoneStranded() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        let started = Latch(), release = Latch()

        let first = Task {
            try await holder.value {
                started.fire()
                await release.wait()
                return ledger.nextBuild()
            }
        }
        await started.wait()
        let second = Task { try await holder.value { ledger.nextBuild() } }
        let third = Task { try await holder.value { ledger.nextBuild() } }
        // Let both pile into the waiter queue before the builder finishes.
        for _ in 0 ..< 200 { await Task.yield() }
        release.fire()

        let values = try await [first.value, second.value, third.value]
        #expect(values == [1, 1, 1])
        #expect(ledger.builds.withLock { $0 } == 1)
    }

    @Test("a retire during the build does not strand the queue either")
    func threeCallersSurviveARetire() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        let started = Latch(), release = Latch()

        let first = Task {
            try await holder.value {
                started.fire()
                await release.wait()
                return ledger.nextBuild()
            }
        }
        await started.wait()
        let second = Task { try await holder.value { ledger.nextBuild() } }
        let third = Task { try await holder.value { ledger.nextBuild() } }
        for _ in 0 ..< 200 { await Task.yield() }
        await holder.retire()          // the world changes mid-build
        release.fire()

        // The builder is told the truth; the two waiters must still finish
        // — one rebuilds, the other is handed that result.
        _ = try? await first.value
        let recovered = try await [second.value, third.value]
        #expect(recovered[0] == recovered[1], "one build, shared")
        #expect(await holder.isResident)
    }

    // MARK: retiring

    @Test("retire hands back what was held, and the next call builds again")
    func retireThenRebuild() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        _ = try await holder.value { ledger.nextBuild() }

        let returned = await holder.retire()
        #expect(returned == 1, "so a caller with something to close can close it")
        #expect(await holder.isResident == false)

        let again = try await holder.value { ledger.nextBuild() }
        #expect(again == 2)
        #expect(ledger.builds.withLock { $0 } == 2)
    }

    @Test("N lever changes leave exactly one resident — AC-145's shape")
    func nChangesOneResident() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        for _ in 1...5 {
            _ = try await holder.value { ledger.nextBuild() }
            await holder.retire()
        }
        _ = try await holder.value { ledger.nextBuild() }
        #expect(await holder.isResident)
        #expect(ledger.builds.withLock { $0 } == 6)
    }

    // MARK: THE HARD ONE — retiring while a build is in flight

    @Test("a build that finishes after a retire does NOT come back to life")
    func retireDuringLoadDoesNotInstall() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>(discard: { value in
            ledger.discarded.withLock { $0.append(value) }
        })
        let started = Latch(), release = Latch()

        // A Task, not `async let`: the #expect macro cannot capture one.
        let building = Task {
            try await holder.value {
                started.fire()
                await release.wait()
                return ledger.nextBuild()
            }
        }
        await started.wait()
        await holder.retire()          // the world changes mid-build
        release.fire()

        await #expect(throws: Retirable<Int>.Failure.retiredDuringLoad) {
            _ = try await building.value
        }
        #expect(await holder.isResident == false,
                "the retired resource must not be resurrected by its own load")
        #expect(ledger.discarded.withLock { $0 } == [1],
                "and the orphan is handed over, not leaked silently")
    }

    @Test("after a retire-during-load the holder is still usable")
    func usableAfterRetireDuringLoad() async throws {
        let ledger = Ledger()
        let holder = Retirable<Int>()
        let started = Latch(), release = Latch()

        let building = Task {
            try await holder.value {
                started.fire()
                await release.wait()
                return ledger.nextBuild()
            }
        }
        await started.wait()
        await holder.retire()
        release.fire()
        _ = try? await building.value

        let fresh = try await holder.value { ledger.nextBuild() }
        #expect(fresh == 2)
        #expect(await holder.isResident)
    }

    @Test("a build that throws leaves nothing resident, and does not wedge the queue")
    func failedBuildDoesNotWedge() async throws {
        struct Boom: Error {}
        let ledger = Ledger()
        let holder = Retirable<Int>()

        await #expect(throws: Boom.self) {
            _ = try await holder.value { throw Boom() }
        }
        #expect(await holder.isResident == false)

        let recovered = try await holder.value { ledger.nextBuild() }
        #expect(recovered == 1, "a failed build must not block every later one")
    }
}
