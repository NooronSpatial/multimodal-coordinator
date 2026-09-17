import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE VENDOR'S TASK ENDS WHEN THE LOOP IS CUT (4y, AC-261, AC-264 — the
// review of this piece).
//
// The vendor's shape, scripted: a stream plus the task producing into
// it, whose `.cancelled` termination cancels that task — and nothing
// else does. The review's probe showed the one path the first cut
// missed: a consumer whose cancel lands while its BODY runs leaves the
// loop by `break`, the stream never terminates as `.cancelled`, and the
// producer runs to its own end. On the phone that is the KV cache
// growing to `maxTokens` while `waitForIdle()` blocks. The producer here
// PARKS instead of running on, so a loop that fails to cancel it is a
// loop that never returns — caught by a cap that lets the producer go
// by hand, so a red run ends in seconds and leaks nothing.

@Suite("4y · the vendor's task is cancelled on every cut of the drain", .timeLimit(.minutes(1)))
struct MLXVendorLoopTests {

    /// A producer the vendor's shape: `count` events into an unbounded
    /// stream, then parked on a gate until it is cancelled — or, on a red
    /// run, until the test opens the gate by hand. It reports which.
    private static func producer(count: Int, gate: TestGate, facts: Facts)
    -> (AsyncStream<Int>, Task<Void, Never>) {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let task = Task {
            for index in 0..<count { continuation.yield(index) }
            await gate.wait()
            facts.send(Task.isCancelled ? "producer ended cancelled" : "producer ended by hand")
            continuation.finish()
        }
        // The vendor's own wiring, verbatim in shape: only a `.cancelled`
        // termination reaches the task.
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return (stream, task)
    }

    /// Races the drain against a cap that, when it wins, lets the parked
    /// producer go so the drain can end and nothing outlives the row.
    private static func drained(_ drain: Task<Bool, Never>, orLetGoBy gate: TestGate) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await drain.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                gate.open()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// THE PATH THE REVIEW CAUGHT: the cancel lands while the body is
    /// running — here, the body cancels its own task on the second event
    /// — so the loop leaves by `break` at the top of the next turn.
    @Test("a cancel that lands while the body runs still cancels the vendor's task, and the drain returns")
    func aCutInTheBodyCancelsTheVendor() async throws {
        let facts = Facts()
        let gate = TestGate()
        let (events, vendor) = Self.producer(count: 3, gate: gate, facts: facts)
        let handle = Mutex<Task<Bool, Never>?>(nil)
        let seen = Mutex<[Int]>([])
        let drain = Task<Bool, Never> {
            await VendorLoop.drain(events, vendor: vendor) { event in
                seen.withLock { $0.append(event) }
                if event == 1 { handle.withLock { $0 }?.cancel() }
            }
        }
        handle.withLock { $0 = drain }

        let onItsOwn = await Self.drained(drain, orLetGoBy: gate)
        // Settled either way now — by the cancel, or by the cap's hand —
        // so what follows is read, not waited for.
        let cut = await drain.value
        #expect(onItsOwn, "the drain must return on its own: the vendor was cancelled, not left running")
        #expect(cut, "the drain reports the cut")
        #expect(facts.log == ["producer ended cancelled"],
                "the vendor's task saw the cancel — the KV cache it owns is gone: \(facts.log)")
        #expect(seen.withLock { $0 } == [0, 1], "the body ran until the cancel, and the next turn left")
    }

    /// The other path: the cancel lands while `next()` is PARKED. A
    /// cancelled `next()` terminates the stream as `.cancelled`, which is
    /// the vendor's own hand on its task — the drain adds its own cancel
    /// on top, idempotently.
    @Test("a cancel that lands while next() is parked cancels the vendor's task too")
    func aCutWhileParkedCancelsTheVendor() async throws {
        let facts = Facts()
        let gate = TestGate()
        let (events, vendor) = Self.producer(count: 3, gate: gate, facts: facts)
        let seen = Mutex<[Int]>([])
        let drain = Task<Bool, Never> {
            await VendorLoop.drain(events, vendor: vendor) { event in
                seen.withLock { $0.append(event) }
                if event == 2 { facts.send("all three seen") }
            }
        }
        #expect(await facts.heard("all three seen"), "the loop is parked in next() with nothing left to read")
        drain.cancel()
        let onItsOwn = await Self.drained(drain, orLetGoBy: gate)
        let cut = await drain.value
        #expect(onItsOwn)
        #expect(cut)
        #expect(facts.log == ["all three seen", "producer ended cancelled"], "\(facts.log)")
        #expect(seen.withLock { $0 } == [0, 1, 2])
    }

    /// A generation that ends on its own is NOT a cut: every event is
    /// handed over, the vendor's task is awaited, and the drain says so —
    /// the caller keeps the buffer pool for the next reply.
    @Test("a stream that ends on its own is drained whole, awaited, and reported as not cut")
    func anUncutStreamIsDrainedWhole() async throws {
        let facts = Facts()
        let gate = TestGate()
        let (events, vendor) = Self.producer(count: 3, gate: gate, facts: facts)
        gate.open()   // the producer finishes right after its three events
        let seen = Mutex<[Int]>([])
        let cut = await VendorLoop.drain(events, vendor: vendor) { event in
            seen.withLock { $0.append(event) }
        }
        #expect(!cut)
        #expect(seen.withLock { $0 } == [0, 1, 2])
        #expect(facts.log == ["producer ended by hand"], "\(facts.log)")
    }
}
