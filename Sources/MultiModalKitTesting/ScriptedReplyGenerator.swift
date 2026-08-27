import MultiModalKit
import Synchronization

/// A reply generator that does exactly what the test says — including the
/// wrong thing, on purpose (test support for SPEC AC-62/AC-63/AC-65).
///
/// Plans, one per reply the coordinator opens:
/// - `.manual` — emits nothing on its own; the test drives `emit`/`finish`/
///   `fail` by hand. Conformant: `cancel()` ends the stream.
/// - `.manual(ignoresCancel: true)` — the DEFIANT plan: `cancel()` is
///   recorded but the stream stays open, so `forceToken`/`forceFinished`
///   can push a real ghost into a dead turn. Proof duty for the ticket.
/// - `.failOnOpen` — `openReply` itself throws.
///
/// Everything is recorded; tests assert against the record, not hope.
public final class ScriptedReplyGenerator: ReplyGenerating, Sendable {
    public enum Plan: Sendable {
        case manual(ignoresCancel: Bool = false)
        case failOnOpen(String)
        /// SUSPENDS inside `openReply` until `releaseOpen()`, then throws.
        /// It exists for one job: holding the coordinator INSIDE its
        /// `await replyGenerator.openReply(...)` so a test can land
        /// `interrupt()` in that exact window. The adversarial review of
        /// 4d found a critical bug living there — the catch arms failed
        /// the turn a second time, after an interruption had already
        /// driven the state to idle — and no existing plan could hold the
        /// door open long enough to prove it.
        case blockThenFailOnOpen(String)
    }

    public struct ReplyRecord: Sendable {
        public var transcript: String
        public var cancelled = false
    }

    private struct State {
        var records: [ReplyRecord] = []
        var continuations: [Int: AsyncStream<ReplyUpdate>.Continuation] = [:]
        /// The one waiting `openReply`, held open for `blockThenFailOnOpen`.
        var openGate: CheckedContinuation<Void, Never>?
        /// True when `releaseOpen()` was called BEFORE anyone waited — the
        /// release must not be lost to a race with the arriving caller.
        var openReleasedEarly = false
    }

    private let plans: [Plan]
    private let state = Mutex(State())

    public init(plans: [Plan]) {
        self.plans = plans
    }

    /// `count` conformant manual replies — the everyday generator.
    public static func manual(replies: Int) -> ScriptedReplyGenerator {
        ScriptedReplyGenerator(plans: Array(repeating: .manual(), count: replies))
    }

    // MARK: - the record

    public var repliesOpened: Int { state.withLock { $0.records.count } }

    public func record(ofReply index: Int) -> ReplyRecord? {
        state.withLock { index < $0.records.count ? $0.records[index] : nil }
    }

    // MARK: - the test's hands (conformant: all guarded by !cancelled)

    public func emit(reply index: Int, token: String) {
        let continuation = state.withLock { state in
            (index < state.records.count && !state.records[index].cancelled)
                ? state.continuations[index] : nil
        }
        continuation?.yield(.token(token))
    }

    public func finish(reply index: Int) {
        let continuation = state.withLock { state in
            (index < state.records.count && !state.records[index].cancelled)
                ? state.continuations.removeValue(forKey: index) : nil
        }
        continuation?.yield(.finished)
        continuation?.finish()
    }

    public func fail(reply index: Int, reason: String) {
        let continuation = state.withLock { state in
            (index < state.records.count && !state.records[index].cancelled)
                ? state.continuations.removeValue(forKey: index) : nil
        }
        continuation?.yield(.failed(reason))
        continuation?.finish()
    }

    // MARK: - the defiant hands (no guards — ghosts on demand)

    /// Pushes a token RIGHT NOW, cancelled or not. If the coordinator
    /// publishes it, the turn ticket failed.
    public func forceToken(reply index: Int, token: String) {
        state.withLock { $0.continuations[index] }?.yield(.token(token))
    }

    public func forceFinished(reply index: Int) {
        state.withLock { $0.continuations[index] }?.yield(.finished)
    }

    // MARK: - ReplyGenerating

    public func openReply(to transcript: String) async throws -> any ReplyRun {
        // Record and continuation land in ONE lock: any observer that can
        // see the record can reach the stream. (The split version lost a
        // race — a test emitting between the two locks yielded into nothing
        // and the update vanished. The older ScriptedTranscriber had this
        // right; the law was re-learned here.)
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        let stream = AsyncStream<ReplyUpdate> { handle = $0 }
        let continuation = handle!
        let (index, plan) = state.withLock { state -> (Int, Plan) in
            state.records.append(ReplyRecord(transcript: transcript))
            let index = state.records.count - 1
            let plan = index < plans.count ? plans[index] : Plan.manual()
            if case .failOnOpen = plan {} else {
                state.continuations[index] = continuation
            }
            return (index, plan)
        }

        if case .failOnOpen(let reason) = plan {
            throw TurnFailure.generationFailed(reason)
        }
        if case .blockThenFailOnOpen(let reason) = plan {
            // Hold the caller here until the test says go. Lock rules
            // (§4.1): the continuation is STORED under the lock and
            // resumed outside it, by `releaseOpen`.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let releaseNow = state.withLock { state -> Bool in
                    if state.openReleasedEarly { return true }
                    state.openGate = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
            throw TurnFailure.generationFailed(reason)
        }
        return ScriptedReply(generator: self, index: index, plan: plan, updates: stream)
    }

    /// Lets a `blockThenFailOnOpen` reply out of `openReply`, so it throws.
    /// Safe to call before anyone is waiting: the release is remembered.
    public func releaseOpen() {
        // Snapshot under the lock, resume OUTSIDE it — never resume a
        // continuation while holding a lock (§4.1's second rule, learned
        // the hard way in Phase 1).
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.openReleasedEarly = true
            return state.openGate.take()
        }
        waiting?.resume()
    }

    fileprivate func cancel(reply index: Int, ignoresCancel: Bool) {
        let continuation = state.withLock { state -> AsyncStream<ReplyUpdate>.Continuation? in
            state.records[index].cancelled = true
            if ignoresCancel { return nil }   // defiance: the stream stays open
            return state.continuations.removeValue(forKey: index)
        }
        continuation?.finish()   // conformant: ends without a terminal update
    }
}

private struct ScriptedReply: ReplyRun {
    let generator: ScriptedReplyGenerator
    let index: Int
    let plan: ScriptedReplyGenerator.Plan
    let updates: AsyncStream<ReplyUpdate>

    func cancel() async {
        let ignores = if case .manual(let flag) = plan { flag } else { false }
        generator.cancel(reply: index, ignoresCancel: ignores)
    }
}
