// 5d PIECE 5's FIX — THE FLOOR (SPEC §265/2, D-148, AC-378's base).
//
//   voice:  hold = floor.take() … hold.giveBack()
//   mind:   await floor.waitWhileTaken()   — at once when free, else until given back or cancelled

@testable import MultiModalKit
import Synchronization
import Testing

@Suite("D-148 · the floor the voice takes and the mind waits for", .timeLimit(.minutes(1)))
struct VoiceFloorTests {

    /// A fact a task can set and a test can read.
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// A waiter on its own task, and a fact when it is done.
    static func waiter(_ floor: VoiceFloor) -> (Task<Void, Never>, Flag) {
        let done = Flag()
        let task = Task { await floor.waitWhileTaken(); done.set() }
        return (task, done)
    }

    @Test("free: the mind goes on at once")
    func freeGoesOn() async {
        let floor = VoiceFloor()
        let (_, done) = Self.waiter(floor)
        let went = await TurnCoordinatorTests.until { done.isSet }
        #expect(went)
        #expect(!floor.isTaken)
    }

    @Test("taken: the mind waits until the hold is given back")
    func takenWaits() async {
        let floor = VoiceFloor()
        let hold = floor.take()
        #expect(floor.isTaken)
        let (_, done) = Self.waiter(floor)
        let parked = await TurnCoordinatorTests.until { floor.waiting == 1 }
        #expect(parked, "the waiter must be parked on the floor")
        #expect(!done.isSet, "and not past it")
        hold.giveBack()
        let went = await TurnCoordinatorTests.until { done.isSet }
        #expect(went, "given back: the waiter goes on")
        #expect(!floor.isTaken)
        #expect(floor.waiting == 0)
    }

    @Test("two holds: free only when both are given back; a second giveBack counts once")
    func twoHolds() async {
        let floor = VoiceFloor()
        let first = floor.take()
        let second = floor.take()
        let (_, done) = Self.waiter(floor)
        let parked = await TurnCoordinatorTests.until { floor.waiting == 1 }
        #expect(parked)
        first.giveBack()
        first.giveBack()                       // counted once
        #expect(floor.isTaken, "one hold is still out")
        #expect(!done.isSet)
        second.giveBack()
        let went = await TurnCoordinatorTests.until { done.isSet }
        #expect(went)
        #expect(!floor.isTaken)
    }

    @Test("a cancel while waiting ends the wait at once, and leaves no waiter behind")
    func cancelEndsTheWait() async {
        let floor = VoiceFloor()
        let hold = floor.take()
        let (task, done) = Self.waiter(floor)
        let parked = await TurnCoordinatorTests.until { floor.waiting == 1 }
        #expect(parked)
        task.cancel()
        let went = await TurnCoordinatorTests.until { done.isSet }
        #expect(went, "a cancelled waiter returns although the floor is still taken")
        #expect(floor.waiting == 0)
        hold.giveBack()
    }
}
