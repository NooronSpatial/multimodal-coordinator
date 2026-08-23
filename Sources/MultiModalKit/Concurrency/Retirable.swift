/// A resource that is built on demand, built **once**, and can be thrown
/// away — including while it is still being built.
///
/// ## The bug this type exists to end
///
/// The same shape has been written by hand three times in this project —
/// in the neural voice, in the Whisper engine, in the local mind — and it
/// has been wrong four times (D-051). The failure is always the same:
///
/// ```swift
/// if let cached { return cached }          // ← check
/// let fresh = try await build()            // ← the actor is RELEASED here
/// cached = fresh                           // ← assign, over somebody else's
/// return fresh
/// ```
///
/// Two callers arrive together, both see `nil`, both build. The most recent
/// time, that loaded the neural voice **twice, concurrently** — two
/// tokenizers and two sets of six CoreML models, "Total model load: 82.26s"
/// beside "74.96s", about 2.2 GB where 1.1 was intended (INSTRUMENTS §28).
///
/// ## And the harder half: retiring during a load
///
/// A caller that changes a setting wants the old resource gone. If a build
/// is in flight when that happens, the naive fix — nil the field — loses,
/// because the in-flight build assigns *after* the nil and the retired
/// resource comes back to life.
///
/// So this follows the project's own law (§4.1): correctness comes from a
/// **monotonic generation ticket**, not from cancellation. `retire()` raises
/// the ticket in one actor step. A build compares the ticket it started with
/// against the ticket it finished with, and a build whose world changed
/// underneath it does not install its result — it hands it to `discard` and
/// tells its caller the truth.
public actor Retirable<Resource: Sendable> {

    public enum Failure: Error, Equatable {
        /// The resource you were waiting for was retired while it was being
        /// built. Not an error in the build — a change of mind, reported
        /// rather than hidden, because the alternative is returning a
        /// resource nobody is tracking.
        case retiredDuringLoad
    }

    private var held: Resource?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Raised by `retire()`. Never lowered, never reused.
    private var generation = 0
    private let discard: @Sendable (Resource) -> Void

    /// - Parameter discard: called with any resource this type is about to
    ///   drop — a build that finished after a retire, or a build that lost a
    ///   race. Default is to simply release it, which is right for anything
    ///   ARC can clean up on its own. Pass a closure when the resource needs
    ///   an explicit close.
    public init(discard: @escaping @Sendable (Resource) -> Void = { _ in }) {
        self.discard = discard
    }

    public var isResident: Bool { held != nil }

    /// The resource, building it if it is absent.
    ///
    /// Concurrent callers do not each build: the first builds, the rest wait
    /// in a FIFO queue and are handed the same instance.
    public func value(
        building build: @Sendable () async throws -> Resource
    ) async throws -> Resource {
        if let held { return held }
        while busy {
            await withCheckedContinuation { waiters.append($0) }
            // Re-checked after every wake, because the actor was released
            // and the world may have moved twice while we slept.
            if let held { return held }
        }
        busy = true
        let startedAt = generation
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }

        let fresh = try await build()

        // THE REENTRANCY LAW. The await above released the actor, so
        // everything below re-checks what that await could have changed.
        guard startedAt == generation else {
            discard(fresh)
            throw Failure.retiredDuringLoad
        }
        if let held {
            discard(fresh)
            return held
        }
        held = fresh
        return fresh
    }

    /// Throws the resource away and returns it, so a caller that needs to
    /// close something can.
    ///
    /// A build in flight when this is called will not install its result.
    @discardableResult
    public func retire() -> Resource? {
        generation &+= 1
        let old = held
        held = nil
        return old
    }
}
