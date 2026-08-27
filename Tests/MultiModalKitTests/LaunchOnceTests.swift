import Foundation
import MultiModalKit
import Synchronization
import Testing

/// The launch sequence's guard (AC-142).
///
/// It exists because three tabs mean three plausible owners of a `.task`,
/// and running the demo's launch twice is not a slow start — it is the
/// jetsam kill recorded three times in INSTRUMENTS §29.
@Suite("launching exactly once")
struct LaunchOnceTests {

    final class Recorder: Sendable {
        let steps = Mutex([String]())
        func note(_ name: String) { steps.withLock { $0.append(name) } }
        var seen: [String] { steps.withLock { $0 } }
    }

    /// A one-shot event, so the concurrency tests gate on a fact.
    final class Latch: Sendable {
        private struct Guarded {
            var fired = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(Guarded())
        func fire() {
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
                let already = state.withLock { guarded -> Bool in
                    if guarded.fired { return true }
                    guarded.waiters.append(continuation)
                    return false
                }
                if already { continuation.resume() }
            }
        }
    }

    @Test("the steps run in the order they were given")
    func orderIsKept() async {
        let recorder = Recorder()
        await LaunchOnce().run([
            { recorder.note("probe") },
            { recorder.note("speech model") },
            { recorder.note("voice") },
            { recorder.note("mind") }
        ])
        #expect(recorder.seen == ["probe", "speech model", "voice", "mind"])
    }

    @Test("THE ORDER THAT KILLS: the voice must precede the mind")
    func voiceBeforeMind() async {
        let recorder = Recorder()
        await LaunchOnce().run([
            { recorder.note("voice") },
            { recorder.note("mind") }
        ])
        let voice = recorder.seen.firstIndex(of: "voice")
        let mind = recorder.seen.firstIndex(of: "mind")
        #expect(voice != nil && mind != nil && voice! < mind!,
                "the voice is born while headroom is highest — §29")
    }

    @Test("two tabs appearing together launch the sequence once, not twice")
    func concurrentCallersRunItOnce() async {
        let recorder = Recorder()
        let launch = LaunchOnce()
        let started = Latch(), release = Latch()

        let first = Task {
            await launch.run([
                { started.fire(); await release.wait(); recorder.note("voice") }
            ])
        }
        await started.wait()                    // the sequence is IN FLIGHT
        let second = Task {
            await launch.run([{ recorder.note("voice") }])
        }
        release.fire()
        _ = await (first.value, second.value)

        #expect(recorder.seen == ["voice"], "the second tab must not reload the voice")
    }

    @Test("the second caller does not return until the sequence is complete")
    func waitersSeeCompletedWork() async {
        let recorder = Recorder()
        let launch = LaunchOnce()
        let started = Latch(), release = Latch()

        let first = Task {
            await launch.run([
                { started.fire(); await release.wait(); recorder.note("voice") }
            ])
        }
        await started.wait()
        let second = Task { () -> [String] in
            await launch.run([{ recorder.note("late") }])
            return recorder.seen           // read AFTER run() returned
        }
        release.fire()
        _ = await first.value
        let seenByWaiter = await second.value
        #expect(seenByWaiter == ["voice"],
                "a caller that returns must be able to rely on the work being done")
    }

    @Test("a call after it has finished does nothing at all")
    func laterCallsAreNoOps() async {
        let recorder = Recorder()
        let launch = LaunchOnce()
        await launch.run([{ recorder.note("first") }])
        await launch.run([{ recorder.note("second") }])
        await launch.run([{ recorder.note("third") }])
        #expect(recorder.seen == ["first"])
        #expect(await launch.hasRun)
    }

    @Test("it says whether it has run")
    func reportsItself() async {
        let launch = LaunchOnce()
        #expect(await launch.hasRun == false)
        await launch.run([])
        #expect(await launch.hasRun)
    }
}
