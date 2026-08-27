import Testing
import Synchronization
import MultiModalKit

// The test double for `AudioSessionSeamTests`, at FILE scope rather than
// nested inside the suite: `enum Step` inside a class inside a struct is
// three levels, and the third buys nothing a reader needs.

final class ScriptedSession: AudioSessionConfiguring, @unchecked Sendable {
    enum Step: Equatable { case activate, deactivate }
    private let store = Mutex<[Step]>([])
    private let failure: (any Error)?
    /// What the microphone was doing at the moment we were released.
    /// The seam's second promise — "released only AFTER the engine
    /// stops" — was previously asserted in a MESSAGE and verified by
    /// nothing, because the session had no view of the engine.
    private let observed = Mutex<Bool?>(nil)
    nonisolated(unsafe) weak var microphone: MicrophoneSource?

    init(failsToActivate: (any Error)? = nil) { self.failure = failsToActivate }

    var steps: [Step] { store.withLock { $0 } }
    var microphoneWasRunningAtRelease: Bool? { observed.withLock { $0 } }

    func activate() throws {
        store.withLock { $0.append(.activate) }
        if let failure { throw failure }
    }

    func deactivate() {
        observed.withLock { $0 = microphone?.isRunning ?? false }
        store.withLock { $0.append(.deactivate) }
    }
}
