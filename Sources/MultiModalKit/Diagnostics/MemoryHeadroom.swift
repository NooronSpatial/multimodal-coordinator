import Foundation
import Synchronization

/// HOW CLOSE THIS PROCESS IS TO BEING KILLED (SPEC 4i, AC-132).
///
/// iOS does not warn before jetsam; it terminates. So the only useful
/// question is asked in advance — how many bytes are left before the
/// DIRTY MEMORY LIMIT — and the only honest answer distinguishes "the
/// platform cannot tell me" from "nothing is left".
///
/// That distinction is the whole reason this type exists, because BOTH
/// of Apple's answers collapse those two facts into the same value:
///
/// - `os_proc_available_memory()` returns 0 when the caller is not an
///   app AND when the caller is over its limit (its own header says so).
/// - `task_vm_info.limit_bytes_remaining` returns 0 on macOS — MEASURED,
///   with the full field count returned, so the field is populated and
///   genuinely zero — because a Mac has no such limit at all.
///
/// A number meaning both "no information" and "you are past the edge" is
/// the lying-instrument shape this project keeps finding. Nothing may
/// read the raw value; they read this.
public enum MemoryHeadroom: Sendable, Equatable {
    /// Bytes remaining before the dirty memory limit.
    case bytes(Int)
    /// At or over the limit. On iOS this is the last thing you learn
    /// before the process is killed.
    case exhausted
    /// The platform cannot answer, and WHY.
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        /// macOS. No dirty memory limit exists, so there is no headroom
        /// to report and zero must NOT be read as exhaustion.
        case noMemoryLimitOnThisPlatform
        /// `task_info` refused.
        case taskInfoFailed(kern_return_t)
        /// The kernel answered with a short struct. `limit_bytes_remaining`
        /// lives past `TASK_VM_INFO_REV3_COUNT` — the header says REV3
        /// "doesn't include limit bytes" — so a short reply leaves the
        /// field UNPOPULATED, and reading it would be reading whatever
        /// happened to be in that memory.
        case fieldNotReported
    }

    /// Megabytes remaining, or nil when there is no number to give.
    /// `exhausted` deliberately answers 0 here and `unavailable` answers
    /// nil — a caller that wants a number must handle "there isn't one".
    public var megabytes: Int? {
        switch self {
        case .bytes(let b): b / 1_048_576
        case .exhausted: 0
        case .unavailable: nil
        }
    }

    /// True only when the instrument is switched ON — the D-054 rule.
    public var isMeasuring: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Reads the headroom. A snapshot, never cached — Apple's header is
/// explicit that the value "may be instantaneously invalidated" and that
/// the limit itself changes during the app lifecycle.
public enum MemoryHeadroomReader {

    public static func read() -> MemoryHeadroom {
        #if os(macOS)
        // Not a guess: measured. `limit_bytes_remaining` comes back 0 on
        // this Mac with the full count returned. Reporting that as
        // `exhausted` would tell a developer their Mac was about to be
        // killed, which is the exact failure this type exists to prevent.
        return .unavailable(.noMemoryLimitOnThisPlatform)
        #else
        var info = task_vm_info_data_t()
        let full = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        var count = full
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(full)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unavailable(.taskInfoFailed(result))
        }
        // The reply must be long enough to have REACHED the field.
        guard count >= full else { return .unavailable(.fieldNotReported) }

        let remaining = info.limit_bytes_remaining
        guard remaining > 0 else { return .exhausted }
        return .bytes(Int(clamping: remaining))
        #endif
    }
}

/// SYSTEM-WIDE MEMORY PRESSURE — the only warning iOS actually gives.
///
/// AC-139 measured a load that killed this app twice while BOTH
/// in-process instruments sat flat: dirty headroom moved 13 MB, and
/// `phys_footprint` went DOWN. The reason is that CoreML prepares models
/// in system daemons, not in the calling process, so the memory is spent
/// outside this address space and charges neither number
/// (INSTRUMENTS §30).
///
/// The kernel does broadcast pressure, though, and that signal is not
/// per-process. It is the one instrument positioned to see a failure
/// caused by somebody else's allocation.
///
/// Deliberately a SEAM rather than a global: the source is a
/// `DispatchSource`, which needs a queue and a lifetime, and this
/// project's rule is that monitoring is opt-in and never ambient
/// (D-026/D-028). Nothing observes until an app asks.
public final class MemoryPressureMonitor: @unchecked Sendable {
    public enum Level: Sendable, Equatable {
        case normal, warning, critical
    }

    private let source: DispatchSourceMemoryPressure

    /// - Parameter onChange: called on the given queue when the system's
    ///   pressure level changes. It is a WARNING, not a budget: by the
    ///   time `.critical` arrives something is already being killed, and
    ///   it may not be this process.
    public init(queue: DispatchQueue = .global(qos: .utility),
                onChange: @escaping @Sendable (Level) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        // WEAK, and only on a CHANGE.
        //
        // The first version captured `source` strongly inside the handler
        // that `source` itself retains — a cycle, so `deinit` could never
        // run. And it called back on EVERY event: under real pressure the
        // kernel fires repeatedly, so a caller that logs would answer
        // memory pressure with a burst of work. Coalescing to transitions
        // is not an optimisation here, it is the difference between an
        // instrument and an accelerant.
        let last = Mutex<Level>(.normal)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let data = source.data
            let level: Level = data.contains(.critical) ? .critical
                             : data.contains(.warning) ? .warning
                             : .normal
            let changed = last.withLock { previous -> Bool in
                guard previous != level else { return false }
                previous = level
                return true
            }
            if changed { onChange(level) }
        }
        source.resume()
    }

    deinit { source.cancel() }
}
