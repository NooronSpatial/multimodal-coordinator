import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// ADMISSION (4y, SPEC §187/1, AC-258, AC-259, D-107 F-1 = A).
//
// Aura's R1: one call that reads the phone's headroom and either BEGINS
// the load in the same step or refuses, typed — no window between the
// check and the allocation that a second caller can fall into. The
// number compared is the APP's (F-1 = A); nothing is inferred from a
// file size (D-105); and a headroom the phone will not give never
// refuses (D-092). Every row here runs on a scripted headroom, because
// this Mac reports none and a phone's cannot be told what to say.

// MARK: - the gate on its own (no weights, no GPU)

@Suite("AC-258 / AC-259 · admission is one step, on the app's number", .timeLimit(.minutes(1)))
struct MLXAdmissionTests {

    /// The headroom the test scripts, read through the same hand the
    /// model reads the kernel's. Shrinkable mid-load, which is the point.
    private final class Headroom: Sendable {
        private let value: Mutex<MemoryHeadroom>
        init(_ initial: MemoryHeadroom) { value = Mutex(initial) }
        func set(_ new: MemoryHeadroom) { value.withLock { $0 = new } }
        var reading: HeadroomReading { { self.value.withLock { $0 } } }
        /// The same hand, and each read is a named FACT — so a test can
        /// say in which ORDER the two callers' checks ran.
        func reading(telling facts: Facts) -> HeadroomReading {
            {
                let read = self.value.withLock { $0 }
                facts.send("headroom read: \(read.bytes.map { "\($0 / Self.gigabyte) GB" } ?? "none")")
                return read
            }
        }
        private static let gigabyte = 1_073_741_824
    }

    private static let gigabyte = 1_073_741_824

    // MARK: AC-259: refuse on a KNOWN shortfall, never on an unknown

    @Test("a known headroom below the need refuses, typed, and no load begins")
    func aKnownShortfallRefuses() async throws {
        let headroom = Headroom(.bytes(2 * Self.gigabyte))
        let gate = MindAdmission(headroom: headroom.reading)
        let loads = Mutex(0)
        await #expect(throws: ReplyFailure.unavailable(
            .notEnoughMemory(needed: 3 * Self.gigabyte, available: 2 * Self.gigabyte))) {
            try await gate.admit(needing: 3 * Self.gigabyte,
                                 resident: { false },
                                 load: { loads.withLock { $0 += 1 } })
        }
        #expect(loads.withLock { $0 } == 0, "a refused admission never touches the weights")
    }

    @Test("a headroom the phone will not give NEVER refuses — D-092")
    func anUnknownHeadroomAdmits() async throws {
        for reason in [MemoryHeadroom.Reason.noMemoryLimitOnThisPlatform,
                       .fieldNotReported, .taskInfoFailed(1)] {
            let headroom = Headroom(.unavailable(reason))
            let gate = MindAdmission(headroom: headroom.reading)
            let loads = Mutex(0)
            try await gate.admit(needing: 3 * Self.gigabyte,
                                 resident: { false },
                                 load: { loads.withLock { $0 += 1 } })
            #expect(loads.withLock { $0 } == 1,
                    "\(reason): a number you do not have is not a number you may refuse on")
        }
    }

    @Test(".exhausted is a KNOWN zero, and refuses with available 0")
    func exhaustedIsZeroAndRefuses() async throws {
        let gate = MindAdmission(headroom: Headroom(.exhausted).reading)
        await #expect(throws: ReplyFailure.unavailable(
            .notEnoughMemory(needed: 1, available: 0))) {
            try await gate.admit(needing: 1, resident: { false }, load: {})
        }
    }

    @Test("a need of 0 bytes is NO claim (D-105's shape): admitted with no memory question")
    func zeroBytesIsNoClaim() async throws {
        let gate = MindAdmission(headroom: Headroom(.exhausted).reading)
        let loads = Mutex(0)
        try await gate.admit(needing: 0, resident: { false },
                             load: { loads.withLock { $0 += 1 } })
        #expect(loads.withLock { $0 } == 1, "0 asks nothing and loads")
    }

    @Test("a headroom EQUAL to the need admits — the refusal is strictly below")
    func equalHeadroomAdmits() async throws {
        let gate = MindAdmission(headroom: Headroom(.bytes(Self.gigabyte)).reading)
        let loads = Mutex(0)
        try await gate.admit(needing: Self.gigabyte, resident: { false },
                             load: { loads.withLock { $0 += 1 } })
        #expect(loads.withLock { $0 } == 1)
    }

    /// The lock-out D-105 removed, kept out: a mind that is loaded and
    /// answering has already been paid for by the headroom, and asking
    /// the question again would refuse the very thing that is resident.
    @Test("weights already RESIDENT are admitted without the memory question")
    func residentWeightsAreAdmitted() async throws {
        let gate = MindAdmission(headroom: Headroom(.bytes(1)).reading)
        let loads = Mutex(0)
        try await gate.admit(needing: 3 * Self.gigabyte, resident: { true },
                             load: { loads.withLock { $0 += 1 } })
        #expect(loads.withLock { $0 } == 1, "the load door is idempotent; admission lets it say so")
    }

    @Test("a load that throws lets the next admission through — the gate is released on every exit")
    func aFailedLoadReleasesTheGate() async throws {
        struct LoadDied: Error {}
        let gate = MindAdmission(headroom: Headroom(.unavailable(.noMemoryLimitOnThisPlatform)).reading)
        await #expect(throws: LoadDied.self) {
            try await gate.admit(needing: 1, resident: { false }, load: { throw LoadDied() })
        }
        let loads = Mutex(0)
        try await Wait4y.settled(Task {
            try await gate.admit(needing: 1, resident: { false },
                                 load: { loads.withLock { $0 += 1 } })
        })
        #expect(loads.withLock { $0 } == 1, "the second admission must not park behind a dead first")
    }

    // MARK: AC-258: no window — the second caller sees the first's allocation

    /// THE PROOF. Headroom 3 GB; two callers each need 2 GB. The first's
    /// load is IN FLIGHT — begun, parked, its 2 GB not yet counted by
    /// the kernel, exactly the 1.7 s a real load spends between the check
    /// and the allocation landing — and the second caller arrives during
    /// it. A gate with a window lets the second read the STALE 3 GB and
    /// admit a second 2 GB the phone does not have (the mutation that
    /// removes the wait does exactly that, and this row goes red). The
    /// one here makes the second wait until the first's load has ENDED
    /// and the headroom shows 1 GB, and refuses it on that number.
    ///
    /// THE RED IS A FACT, NOT A COIN (the review of this piece): the row
    /// gates on the second caller being PARKED at the gate before it
    /// lets the first's load end. Without that gate the mutant passed
    /// one run in ten — whenever the scheduler ran the second admission
    /// only after the first load had landed, the stale-read window was
    /// simply never entered. With it, a gate that does not park never
    /// sends the fact, and the row dies on its cap.
    @Test("two concurrent callers: the second is refused on the post-allocation headroom, not the stale one")
    func theSecondCallerSeesTheFirstsAllocation() async throws {
        let headroom = Headroom(.bytes(3 * Self.gigabyte))
        let facts = Facts()
        let gate = MindAdmission(headroom: headroom.reading(telling: facts))
        let door = TestGate()
        let loads = Mutex(0)

        let firstLoad: @Sendable () async throws -> Void = {
            loads.withLock { $0 += 1 }
            facts.send("first load began")
            await door.wait()
            headroom.set(.bytes(1 * Self.gigabyte))     // the allocation lands, as the kernel sees it
            facts.send("first load ended")
        }
        let first = Task {
            try await gate.admit(needing: 2 * Self.gigabyte, resident: { false }, load: firstLoad)
        }
        #expect(await facts.heard("first load began"), "the first admission must begin its load")

        let secondLoad: @Sendable () async throws -> Void = {
            loads.withLock { $0 += 1 }
            facts.send("second load began")
        }
        let second = Task {
            try await gate.admit(needing: 2 * Self.gigabyte, resident: { false }, load: secondLoad)
        }
        // The second caller is parked BEHIND the first's load, not
        // admitted beside it — and PARKED is the event waited for here,
        // before the door opens, so the mutant that never parks is
        // caught on every run. The proof is then the ORDER of the facts,
        // read once both callers have settled — the second's headroom
        // read comes AFTER "first load ended", on the 1 GB the allocation
        // left — not a negative wait on wall time (the review: "nothing
        // for 200 ms" is what a slow runner also says).
        #expect(await Wait4y.fact { await gate.parked.wait(atLeast: 1) },
                "the second caller must be parked at the gate while the first's load is in flight")
        door.open()
        try await Wait4y.settled(first)
        await #expect(throws: ReplyFailure.unavailable(
            .notEnoughMemory(needed: 2 * Self.gigabyte, available: 1 * Self.gigabyte))) {
            try await Wait4y.settled(second)
        }
        #expect(loads.withLock { $0 } == 1, "exactly one load: the second was refused on the number the first left")
        #expect(facts.log == ["headroom read: 3 GB", "first load began", "first load ended", "headroom read: 1 GB"],
                "a second admission during the first's load is a window — AC-258 forbids it: \(facts.log)")
    }

    /// The other side of the same coin: enough left after the first, and
    /// the second is ADMITTED on the post-allocation number.
    @Test("two concurrent callers: the second is admitted when the post-allocation headroom still fits it")
    func theSecondCallerIsAdmittedOnThePostAllocationNumber() async throws {
        let headroom = Headroom(.bytes(3 * Self.gigabyte))
        let gate = MindAdmission(headroom: headroom.reading)
        let facts = Facts()
        let door = TestGate()

        let firstLoad: @Sendable () async throws -> Void = {
            facts.send("first load began")
            await door.wait()
            headroom.set(.bytes(2 * Self.gigabyte))
        }
        let first = Task {
            try await gate.admit(needing: 1 * Self.gigabyte, resident: { false }, load: firstLoad)
        }
        #expect(await facts.heard("first load began"))
        let secondLoad: @Sendable () async throws -> Void = { facts.send("second load began") }
        let second = Task {
            try await gate.admit(needing: 2 * Self.gigabyte, resident: { false }, load: secondLoad)
        }
        door.open()
        try await Wait4y.settled(first)
        try await Wait4y.settled(second)
        #expect(await facts.heard("second load began"), "2 GB left, 2 GB needed: admitted")
    }

    // MARK: the model's own door, wired to the gate

    /// AC-259's other half on the real door: an unknown headroom admits,
    /// and what the caller then hears is the LOAD door's own verdict —
    /// on this Mac, that the weights are not there; on a runner with no
    /// metallib, that there is no GPU. The verdict is READ, not typed
    /// here, so the row is honest on both.
    @Test("with no headroom number the model admits, and the load door speaks next")
    func theModelAdmitsOnAnUnknownNumberAndTheLoadDoorSpeaks() async throws {
        let model = LocalMindModel(weights: Self.nowhere(),
                                   headroom: Headroom(.unavailable(.noMemoryLimitOnThisPlatform)).reading,
                                   pressure: ScriptedPressureSource())
        let verdict = try #require(model.readiness(), "no weights: this machine must have a verdict")
        await #expect(throws: ReplyFailure.unavailable(verdict)) {
            try await model.admit(needing: 3 * Self.gigabyte)
        }
    }

    /// A device that could not load anyway is told THAT, not a memory
    /// number: the readiness verdict is asked first, so the memory
    /// question is only ever put to a device that could load.
    @Test("a device that cannot load is refused with its readiness verdict, not a memory number")
    func readinessSpeaksBeforeMemory() async throws {
        let model = LocalMindModel(weights: Self.nowhere(),
                                   headroom: Headroom(.bytes(1)).reading,
                                   pressure: ScriptedPressureSource())
        let verdict = try #require(model.readiness(), "no weights: this machine must have a verdict")
        await #expect(throws: ReplyFailure.unavailable(verdict)) {
            try await model.admit(needing: 1_000)
        }
    }

    /// A directory that does not exist — so the install state is `.absent`
    /// and the load door refuses on every machine.
    private static func nowhere() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "mmk-4y-no-weights-\(UUID().uuidString)")
    }
}
