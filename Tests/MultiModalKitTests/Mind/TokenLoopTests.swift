// 5d PIECE 5's FIX — OUR OWN TOKEN LOOP (SPEC §266b, D-149; AC-382, AC-383).
//
// The vendor's loop, done by us so it can wait for the floor between tokens.
// On scripted tokens: what it does with each, why it ends, and that it asks
// for no new token while the voice holds the floor.

@testable import MultiModalKit
@testable import MultiModalKitMLX
import MLXLMCommon
import Synchronization
import Testing

/// How many times `next()` was asked — a class, so a copy of the iterator
/// counts into the same place.
final class CallCount: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// A scripted iterator: `script` in order, nil at the end or at the budget.
struct ScriptedLoopTokens: LoopTokens {
    var script: [Int]
    var maxTokens: Int?
    var tokenCount = 0
    let calls = CallCount()
    var discarded = 0
    /// Runs as token `index` is handed out (0-based) — where a test lands its event.
    var onNext: @Sendable (Int) -> Void = { _ in }

    init(_ script: [Int], maxTokens: Int? = nil, onNext: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.script = script
        self.maxTokens = maxTokens
        self.onNext = onNext
    }

    mutating func next() -> Int? {
        calls.add()
        if let maxTokens, tokenCount >= maxTokens { return nil }
        guard tokenCount < script.count else { return nil }
        let token = script[tokenCount]
        onNext(tokenCount)
        tokenCount += 1
        return token
    }

    mutating func discardGeneratedToken() { discarded += 1 }
}

/// What the loop handed on, kept across the task boundary.
final class Handed: Sendable {
    private let kept = Mutex<[Int]>([])
    func add(_ token: Int) { kept.withLock { $0.append(token) } }
    var tokens: [Int] { kept.withLock { $0 } }
}

@Suite("AC-382, AC-383 · our own token loop", .timeLimit(.minutes(1)))
struct TokenLoopTests {

    static let stopToken = 99

    @Test("every token once, in order; a stop token ends it with .stop, unspoken and discarded")
    func tokensThenStop() async {
        var tokens = ScriptedLoopTokens([1, 2, 3, Self.stopToken, 4])
        let handed = Handed()
        let reason = await TokenLoop.run(&tokens, isStop: { $0 == Self.stopToken }, floor: nil,
                                              each: { handed.add($0) })
        #expect(handed.tokens == [1, 2, 3])
        #expect(reason == .stop)
        #expect(tokens.discarded == 1, "the stop token is dropped from the iterator, as the vendor does")
        #expect(tokens.calls.count == 4, "nothing asked for after the stop")
    }

    @Test("the budget ends it with .length")
    func theBudget() async {
        var tokens = ScriptedLoopTokens([1, 2, 3, 4, 5], maxTokens: 3)
        let handed = Handed()
        let reason = await TokenLoop.run(&tokens, isStop: { $0 == Self.stopToken }, floor: nil,
                                              each: { handed.add($0) })
        #expect(handed.tokens == [1, 2, 3])
        #expect(reason == .length)
    }

    @Test("a cancel at a token ends it as cancelled, asking for no more")
    func aCancel() async {
        let handed = Handed()
        let started = Mutex(false)
        let task = Task { () -> GenerateStopReason in
            var tokens = ScriptedLoopTokens([1, 2, 3, 4, 5], onNext: { index in
                if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
            started.withLock { $0 = true }
            return await TokenLoop.run(&tokens, isStop: { $0 == Self.stopToken }, floor: nil,
                                              each: { handed.add($0) })
        }
        let reason = await task.value
        #expect(started.withLock { $0 })
        #expect(reason == .cancelled)
        #expect(handed.tokens.count <= 2, "the token in hand at most, then nothing")
    }

    @Test("with the floor taken, no new token after the one in hand; given back, it goes on")
    func theFloor() async {
        let floor = VoiceFloor()
        let hold = Mutex<FloorHold?>(nil)
        let handed = Handed()
        let calls = Mutex(0)
        let task = Task { () -> GenerateStopReason in
            var tokens = ScriptedLoopTokens([1, 2, 3])
            let reason = await TokenLoop.run(&tokens, isStop: { $0 == Self.stopToken }, floor: floor, each: { token in
                handed.add(token)
                // The voice cuts its first phrase on the first token and takes the floor.
                if token == 1 { hold.withLock { $0 = floor.take() } }
            })
            calls.withLock { $0 = tokens.calls.count }
            return reason
        }
        let parked = await TurnCoordinatorTests.until { floor.waiting == 1 }
        #expect(parked, "the loop waits on the floor after the token in hand")
        #expect(handed.tokens == [1], "and asks for nothing more meanwhile")
        hold.withLock { $0?.giveBack() }
        let reason = await task.value
        #expect(handed.tokens == [1, 2, 3], "given back: every token, once, in order")
        #expect(reason == .stop || reason == .cancelled || reason == .length)
        #expect(calls.withLock { $0 } == 4, "three tokens and the end")
    }

    @Test("a cancel while the loop waits for the floor ends it at once")
    func aCancelWhileWaiting() async {
        let floor = VoiceFloor()
        let hold = floor.take()
        let handed = Handed()
        let task = Task { () -> GenerateStopReason in
            var tokens = ScriptedLoopTokens([1, 2, 3])
            return await TokenLoop.run(&tokens, isStop: { $0 == Self.stopToken }, floor: floor,
                                         each: { handed.add($0) })
        }
        let parked = await TurnCoordinatorTests.until { floor.waiting == 1 }
        #expect(parked, "taken before the first token: the loop waits before asking")
        task.cancel()
        let reason = await task.value
        #expect(reason == .cancelled)
        #expect(handed.tokens.isEmpty)
        hold.giveBack()
    }
}
