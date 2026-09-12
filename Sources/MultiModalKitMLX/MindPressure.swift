// THE PHONE'S OWN NUMBERS, INJECTED (4y, SPEC §186–§187, D-107).
//
// Admission and pressure are built on what the phone SAYS — its headroom
// and its pressure level — never on what the library guesses from a
// file size (D-105). Both readings already exist in `MultiModalKit`
// (`MemoryHeadroomReader`, `MemoryPressureMonitor`); this file is the
// two seams that let the mind read them through a hand a test can hold,
// and the one registry a memory warning needs to reach a generation
// that is already running.

import Foundation
import MultiModalKit
import Synchronization

// MARK: - the headroom, as a hand (AC-258, AC-259)

/// How the mind reads the phone's headroom at admission: bytes REMAINING
/// before the dirty-memory limit, or no number at all. The default is
/// the one live reader; a test scripts a number that shrinks when a load
/// begins, which is the only way AC-258's "no window" can be PROVED
/// rather than argued.
///
/// The value is `MemoryHeadroom`, not `Int?`, on purpose: `.unavailable`
/// and `.exhausted` are different facts (the type's own note), and D-092's
/// rule — never refuse on a number you do not have — is a rule about the
/// first one only.
public typealias HeadroomReading = @Sendable () -> MemoryHeadroom

// MARK: - the pressure, as a seam (AC-261, AC-262, AC-263)

/// Where memory-pressure levels come from. The real source is the
/// kernel's dispatch source, wrapped by `MemoryPressureMonitor`; a test's
/// source is a hand that pushes `.warning` when the script says so. The
/// mind subscribes ONCE, for its whole life, and the handler it hands
/// over does no work (AC-263) — see `LocalMindModel`'s init.
public protocol MemoryPressureSourcing: Sendable {
    /// Start delivering level CHANGES to `onChange`, on the source's own
    /// thread, until the returned subscription is cancelled. The handler
    /// must be cheap: the real source calls it from a dispatch queue
    /// while the kernel is already short of memory.
    func subscribe(
        onChange: @escaping @Sendable (MemoryPressureMonitor.Level) -> Void
    ) -> MemoryPressureSubscription
}

/// One live subscription; `cancel()` ends it, idempotently. A class, so
/// the mind can hold it and drop it in `deinit` — the DispatchSource
/// underneath needs a lifetime, and this is the object that has one.
public final class MemoryPressureSubscription: Sendable {
    private let stop: Mutex<(@Sendable () -> Void)?>

    public init(cancel: @escaping @Sendable () -> Void) {
        self.stop = Mutex(cancel)
    }

    /// Ends the subscription. The closure is taken under the lock and RUN
    /// outside it (the lock rule): the real one releases a monitor whose
    /// `deinit` cancels a dispatch source, and nothing of ours should hold
    /// a lock while the system does that.
    public func cancel() {
        let taken = stop.withLock { slot -> (@Sendable () -> Void)? in
            defer { slot = nil }
            return slot
        }
        taken?()
    }
}

/// The real source: `MemoryPressureMonitor`, which already coalesces the
/// kernel's bursts into transitions (its own note — "an instrument, not
/// an accelerant"). Cancelling the subscription drops the monitor, whose
/// `deinit` cancels the dispatch source.
public struct SystemMemoryPressureSource: MemoryPressureSourcing {
    public init() {}

    public func subscribe(
        onChange: @escaping @Sendable (MemoryPressureMonitor.Level) -> Void
    ) -> MemoryPressureSubscription {
        let monitor = Mutex<MemoryPressureMonitor?>(MemoryPressureMonitor(onChange: onChange))
        return MemoryPressureSubscription {
            monitor.withLock { $0 = nil }
        }
    }
}

// MARK: - the runs a warning must reach (AC-261)

/// Every `MLXReplyRun` alive on one model's weights, so a memory warning
/// can end them all the way a barge ends one: through each run's own
/// retired latch, with no terminal (D-107 F-3 = A).
///
/// WEAK on purpose. A run registers itself when it is born and removes
/// itself on every terminal path, but a run its owner dropped mid-round
/// must not be kept alive by the table that exists to kill it; a weak
/// slot lets ARC end it and `abandonAll` skip the empty slot.
///
/// The ticket doctrine (§4.1) is what makes this enough: `abandon()` is
/// the run's `cancel()` — it raises the run's `retired` flag in the same
/// locked step that finishes the stream, so a token the vendor produces
/// AFTER the warning is provably unable to reach a listener. The
/// generation is then cancelled as the OPTIMISATION, and the source's
/// end path frees the prefill (`MLXTokenSource.stream`).
final class LiveRunRegistry: Sendable {
    private struct Slot {
        weak var run: MLXReplyRun?
    }

    private let runs = Mutex<[ObjectIdentifier: Slot]>([:])

    func add(_ run: MLXReplyRun) {
        runs.withLock { $0[ObjectIdentifier(run)] = Slot(run: run) }
    }

    func remove(_ run: MLXReplyRun) {
        runs.withLock { $0[ObjectIdentifier(run)] = nil }
    }

    /// How many runs are registered — slots whose run is gone included,
    /// until the next `abandonAll` sweeps them. A test's question.
    var count: Int {
        runs.withLock { table in table.values.filter { $0.run != nil }.count }
    }

    /// Ends every live run with no terminal, and returns how many. The
    /// table is SNAPSHOTTED under the lock and each run is ended OUTSIDE
    /// it (lock rule 2): `abandon()` finishes a stream, and a stream's
    /// termination handler is somebody else's code.
    @discardableResult
    func abandonAll() -> Int {
        let live = runs.withLock { table -> [MLXReplyRun] in
            defer { table = [:] }
            return table.values.compactMap(\.run)
        }
        for run in live { run.abandon() }
        return live.count
    }
}
