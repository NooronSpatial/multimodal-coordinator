// The double that the `ReplyConformanceTests` suites drive: the scripted
// snapshot source. The suite's own file holds the conformance kit and the
// facts this double is used to pin.

import Synchronization
@testable import MultiModalKit

// MARK: - the scripted source (the TTSDecoding precedent, one seam over)

/// A snapshot stream the TEST drives — including the wrong thing, on
/// purpose. It reaches the internal `ReplySnapshotStreaming` seam via
/// `@testable`, which is the D-053 shape: the second implementation is a
/// test double, so the seam stays internal.
final class ScriptedSnapshotSource: ReplySnapshotStreaming, @unchecked Sendable {
    enum Plan: Sendable {
        /// Yields these cumulative snapshots, then finishes.
        case snapshots([String])
        /// Yields, then throws — the failure a real model cannot be
        /// asked to perform (AC-114's whole reason).
        case snapshotsThenThrow([String], any Error)
        /// Spins until the run's task is cancelled — the hands-off and
        /// cancel cases. Capped, so a red test dies fast, never hangs.
        case spinsUntilCancelled
        /// GATED DEFIANCE. Yields `before`, then holds until the TEST
        /// calls `release()` — which the test does only AFTER its cancel
        /// has returned — then defiantly yields `after`, ignoring
        /// cancellation. The gate is what makes the promise DETERMINISTIC:
        /// the first shape of this test asserted `updates.isEmpty` with no
        /// ordering between the worker's first yield and the cancel, and
        /// the review MEASURED the flake — ~1 leak in 800 runs, five
        /// independent 20,000-run probes — because a PRE-cancel token is
        /// legal under the seam contract and survives `finish()` in the
        /// stream's buffer. Production was right; the assertion conflated
        /// "nothing after cancel" with "nothing at all".
        case gatedDefiance(before: String, after: String)
    }

    var unavailable: (any Error)? { nil }

    private let plan: Plan
    private struct Counts {
        var yielded = 0
        var capExhausted = false
        var released = false
        var sawCancellation = false
    }
    private let counts = Mutex(Counts())

    init(_ plan: Plan) { self.plan = plan }

    var snapshotsYielded: Int { counts.withLock { $0.yielded } }
    var capExhausted: Bool { counts.withLock { $0.capExhausted } }
    /// True once this source OBSERVED the run's cancellation reach its
    /// task — the deterministic fact that replaced the inert
    /// `!capExhausted` assertion: deleting the run's `work.cancel()` was
    /// measured leaving all 13 tests green, because the bounded drain
    /// returned long before the spin cap could trip. THIS flag cannot be
    /// mistaken that way: it is set only by cancellation actually
    /// arriving.
    var sawCancellation: Bool { counts.withLock { $0.sawCancellation } }
    /// Opens the gate: the defiant `after` snapshots may now flow.
    func release() { counts.withLock { $0.released = true } }

    func snapshots(for prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch plan {
                case .snapshots(let all):
                    yieldAll(all, into: continuation)
                    continuation.finish()
                case .snapshotsThenThrow(let all, let error):
                    yieldAll(all, into: continuation)
                    continuation.finish(throwing: error)
                case .spinsUntilCancelled:
                    await spinUntilCancelled(into: continuation)
                case .gatedDefiance(let before, let after):
                    await defyTheGate(before: before, after: after, into: continuation)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The shared body of the two scripted plans, which differ only in
    /// how they END.
    private func yieldAll(
        _ all: [String],
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) {
        for snapshot in all {
            continuation.yield(snapshot)
            counts.withLock { $0.yielded += 1 }
        }
    }

    private func spinUntilCancelled(
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async {
        for _ in 0..<100_000 {
            if Task.isCancelled {
                counts.withLock { $0.sawCancellation = true }
                continuation.finish()
                return
            }
            await Task.yield()
        }
        counts.withLock { $0.capExhausted = true }
        continuation.finish()
    }

    private func defyTheGate(
        before: String,
        after: String,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async {
        continuation.yield(before)
        counts.withLock { $0.yielded += 1 }
        // Hold at the gate. Cancellation is RECORDED here (the
        // deterministic cancel-propagation fact) but NOT obeyed
        // — that is the defiance. Capped so a red dies fast.
        var opened = false
        for _ in 0..<200_000 {
            if Task.isCancelled {
                counts.withLock { $0.sawCancellation = true }
            }
            if counts.withLock({ $0.released }) { opened = true; break }
            await Task.yield()
        }
        if !opened { counts.withLock { $0.capExhausted = true } }
        // THE DEFIANT YIELD, after the test's cancel returned.
        continuation.yield(after)
        counts.withLock { $0.yielded += 1 }
        continuation.finish()
    }
}
