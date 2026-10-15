import Synchronization

/// THE VOICE GOES FIRST (5d piece 5, D-147–D-149): a small floor shared by the
/// voice and the mind, which run on one GPU.
///
///     voice:  let hold = floor.take()   … decode the first phrase …   hold.giveBack()
///     mind:   between two tokens:  await floor.waitWhileTaken()
///
/// While the voice holds the floor, the mind starts no new token; it goes on the
/// moment the floor is given back. The mind is far ahead of the speech, so the
/// wait is never heard; the voice decodes alone (×1.56–1.58 faster on the Mac,
/// AC-377). Handed to both organs by the app that builds them; neither the
/// coordinator nor a mind or voice that is not given one changes.
///
/// The lock rules (the house's): nothing is held across a suspension, and a
/// waiter is resumed OUTSIDE the lock — taken out under it, resumed after.
public final class VoiceFloor: Sendable {
    private struct State {
        var holds = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var nextWaiter = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// The voice takes the floor. Give the hold back on EVERY way the work ends.
    public func take() -> FloorHold {
        state.withLock { $0.holds += 1 }
        return FloorHold(floor: self)
    }

    /// Whether any hold is out.
    public var isTaken: Bool { state.withLock { $0.holds > 0 } }

    /// The mind: returns at once when the floor is free; otherwise waits until
    /// it is given back — or until the waiting task is cancelled.
    public func waitWhileTaken() async {
        let id = state.withLock { state -> Int in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Free, or already cancelled: go on at once. Checked under the
                // lock with the registration, so a cancel can never land
                // between the two and leave the waiter parked.
                let goOn = state.withLock { state -> Bool in
                    if state.holds == 0 || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if goOn { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// How many tasks are waiting now (a fact for tests).
    var waiting: Int { state.withLock { $0.waiters.count } }

    /// One hold given back: at the last, every waiter goes on.
    fileprivate func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holds -= 1
            guard state.holds == 0 else { return [] }
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// One hold on the floor. Given back once; a second `giveBack` does nothing.
public final class FloorHold: Sendable {
    private let floor: VoiceFloor
    private let given = Mutex(false)

    fileprivate init(floor: VoiceFloor) { self.floor = floor }

    public func giveBack() {
        let first = given.withLock { given -> Bool in
            defer { given = true }
            return !given
        }
        if first { floor.release() }
    }
}
