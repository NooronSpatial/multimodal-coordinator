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
/// - `.callsTool` — the reply CALLS a tool, inside the run (4w, F-1 = B):
///   the script says which name, which arguments, what is said before
///   and after, and what happens when the call fails. The tools come
///   from the table handed to `init` (F-2 = A); the coordinator's
///   stream still sees only tokens and one terminal.
///
/// Heat (4y, AC-260, D-107 F-2 = A): the mind is built with a thermometer
/// and a `GenerationThermalPolicy`, the way it is built with tools, and
/// `openReply` asks the policy BEFORE it records or opens anything —
/// the same door the readiness verdict uses in the real minds. A refused
/// door throws `ReplyFailure.tooHot(state)`, consumes no plan, and is
/// counted in `heatRefusals`. The defaults are the real provider and the
/// shipped policy, so every pre-4y call site is unchanged.
///
/// A deadline (4y, AC-264, D-107 F-4 = A) is an ENDING the test scripts by
/// hand: `finish(reply:stop: .deadline)` after the tokens "said so far".
/// The real minds own the clock; this mind only proves the shape the
/// coordinator and a text caller see.
///
/// Everything is recorded; tests assert against the record, not hope.
public final class ScriptedReplyGenerator: ReplyGenerating, Sendable {
    public enum Plan: Sendable {
        case manual(ignoresCancel: Bool = false)
        case failOnOpen(String)
        /// A reply that asks for a tool — the SPIKE's scripted mind (4w,
        /// AC-221). Unlike `.manual` the run drives itself once opened,
        /// because that is what a real mind does with a call: the test
        /// controls the TOOL (`ScriptedTool`), not the reply's hands.
        case callsTool(ToolScript)
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
        /// EVERYTHING the seam was handed, kept whole (4r, F-1 = B). The
        /// record is where AC-190 and AC-191 are proven, so it must hold
        /// the past as well as the present — and hold it in ROLES, or the
        /// test could not tell a flattened seam from a working one.
        public var context: ReplyContext
        public var cancelled = false
        /// Every tool call this reply made, in order (4w). Empty for a
        /// reply whose plan never calls one.
        public var toolCalls: [ToolCallRecord] = []

        /// The thought being answered — the shape tests have read since 4a.
        public var transcript: String { context.transcript }
        /// What the mind was allowed to remember.
        public var history: [ConversationTurn] { context.history }
    }

    private struct State {
        var records: [ReplyRecord] = []
        var continuations: [Int: AsyncStream<ReplyUpdate>.Continuation] = [:]
        /// The one waiting `openReply`, held open for `blockThenFailOnOpen`.
        var openGate: CheckedContinuation<Void, Never>?
        /// True when `releaseOpen()` was called BEFORE anyone waited — the
        /// release must not be lost to a race with the arriving caller.
        var openReleasedEarly = false
        /// The self-driving `.callsTool` runs, by reply index — held so a
        /// conformant `cancel()` can stop the wasted work (the
        /// optimization; the cancelled flag is the guarantee).
        var toolRuns: [Int: Task<Void, Never>] = [:]
        /// Every door the policy shut, with the state it was shut at (4y,
        /// AC-260). A refused door has no record — no reply was opened —
        /// so the count lives here, beside the records, not in them.
        var heatRefusals: [ThermalState] = []
    }

    private let plans: [Plan]
    /// The tools this mind was GIVEN (4w, F-2 = A): at construction, by
    /// the test that plays the app — never by the coordinator.
    public let tools: ToolTable
    /// The thermometer and the policy this mind was GIVEN (4y, AC-260),
    /// handed in the same way as the tools. The defaults are the real
    /// ones, so a test that says nothing about heat runs as it always did.
    public let thermal: any ThermalStateProviding
    public let thermalPolicy: any GenerationThermalPolicy
    private let state = Mutex(State())

    public init(plans: [Plan], tools: ToolTable = .empty,
                thermal: any ThermalStateProviding = SystemThermalProvider(),
                thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy()) {
        self.plans = plans
        self.tools = tools
        self.thermal = thermal
        self.thermalPolicy = thermalPolicy
    }

    /// `count` conformant manual replies — the everyday generator.
    public static func manual(replies: Int) -> ScriptedReplyGenerator {
        ScriptedReplyGenerator(plans: Array(repeating: .manual(), count: replies))
    }

    // MARK: - the record

    public var repliesOpened: Int { state.withLock { $0.records.count } }

    /// The doors the policy shut, in order, each with the state it read
    /// (4y, AC-260). Empty on a cool mind.
    public var heatRefusals: [ThermalState] { state.withLock { $0.heatRefusals } }

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

    /// Ends the reply well. A script that just says "finished" means the
    /// model ended its turn (`.complete`); a text test can script the
    /// other reasons (4v, AC-237) — including `.deadline` (4y, AC-264):
    /// emit the tokens "said so far", then finish with it, and the reply
    /// ends the way a real mind's clock would end it.
    public func finish(reply index: Int, stop: StopReason = .complete) {
        let continuation = state.withLock { state in
            (index < state.records.count && !state.records[index].cancelled)
                ? state.continuations.removeValue(forKey: index) : nil
        }
        continuation?.yield(.finished(stop))
        continuation?.finish()
    }

    /// The pre-4v hand, kept: a string reason is the engine's own words,
    /// and the coordinator carries them verbatim (AC-242).
    public func fail(reply index: Int, reason: String) {
        fail(reply: index, with: .engine(reason))
    }

    /// The typed hand (4v, AC-236/AC-237): script exactly the failure a
    /// counting caller should see.
    public func fail(reply index: Int, with failure: ReplyFailure) {
        let continuation = state.withLock { state in
            (index < state.records.count && !state.records[index].cancelled)
                ? state.continuations.removeValue(forKey: index) : nil
        }
        continuation?.yield(.failed(failure))
        continuation?.finish()
    }

    // MARK: - the defiant hands (no guards — ghosts on demand)

    /// Pushes a token RIGHT NOW, cancelled or not. If the coordinator
    /// publishes it, the turn ticket failed.
    public func forceToken(reply index: Int, token: String) {
        state.withLock { $0.continuations[index] }?.yield(.token(token))
    }

    public func forceFinished(reply index: Int) {
        state.withLock { $0.continuations[index] }?.yield(.finished(.complete))
    }

    // MARK: - ReplyGenerating

    public func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        // THE DOOR (4y, AC-260, D-107 F-2 = A): the policy is asked FIRST,
        // with the thermometer's state right now, before a plan is
        // consumed or a record made — the line the real minds' readiness
        // verdict sits on (`if let verdict = readiness() { throw ... }`).
        // No run exists after a refusal, so nothing can be said, cancelled
        // or remembered; the refusal is typed, and counted here so a test
        // can prove the door was asked, not merely that a plan was missing.
        let heat = thermal.current
        if !thermalPolicy.allowGeneration(thermal: heat) {
            state.withLock { $0.heatRefusals.append(heat) }
            throw ReplyFailure.tooHot(heat)
        }
        // Record and continuation land in ONE lock: any observer that can
        // see the record can reach the stream. (The split version lost a
        // race — a test emitting between the two locks yielded into nothing
        // and the update vanished. The older ScriptedTranscriber had this
        // right; the law was re-learned here.)
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        let stream = AsyncStream<ReplyUpdate> { handle = $0 }
        let continuation = handle!
        let (index, plan) = state.withLock { state -> (Int, Plan) in
            state.records.append(ReplyRecord(context: context))
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
        if case .callsTool(let script) = plan {
            // THE RUN DRIVES ITSELF (F-1 = B): the call happens in here,
            // in a task the run owns, exactly where a real mind's decode
            // loop would make it. Unstructured on purpose — this is test
            // support, and the coordinator must be able to barge while
            // the task is parked inside a tool that never returns
            // (AC-224); a structured child of `openReply` could not
            // outlive the call that opened it. Stored under the lock so
            // `cancel()` can find it.
            let run = Task { await self.runToolScript(script, reply: index) }
            state.withLock { $0.toolRuns[index] = run }
        }
        return ScriptedReply(generator: self, index: index, plan: plan, updates: stream)
    }

    // MARK: - the self-driving tool reply (4w, F-1 = B)

    /// Says `before`, makes the call, says the answer, says `after`,
    /// finishes — or ends the way `onFailure` scripts. Every push goes
    /// through the same `!cancelled` guard the test's hands use, unless
    /// the script is defiant, in which case NOTHING is guarded: the
    /// ghost is the point.
    private func runToolScript(_ script: ToolScript, reply index: Int) async {
        defer { script.whenDone() }
        let force = script.ignoresCancel
        for token in script.before {
            push(.token(token), reply: index, force: force)
        }

        let call = state.withLock { state -> Int in
            state.records[index].toolCalls.append(
                ToolCallRecord(name: script.name, arguments: script.arguments))
            return state.records[index].toolCalls.count - 1
        }
        let outcome = await tools.call(script.name, arguments: script.arguments)

        // THE REENTRANCY LAW (§4.1): the tool took as long as it took, and
        // a barge may have cancelled this reply in the meantime. A
        // conformant run re-checks and drops the answer HERE — its stream
        // is already finished, so a push would go nowhere anyway, but the
        // record says the drop was a decision, not an accident. A defiant
        // run pushes regardless: that is what proves the coordinator's
        // ticket (AC-226).
        let dropped = state.withLock { state -> Bool in
            state.records[index].toolCalls[call].outcome = switch outcome {
            case .success(let answer): .answered(answer)
            case .failure(let failure): .failed(failure)
            }
            let dropped = state.records[index].cancelled && !force
            state.records[index].toolCalls[call].answerDropped = dropped
            return dropped
        }
        if dropped { return }

        switch outcome {
        case .success(let answer):
            push(.token(answer), reply: index, force: force)
            for token in script.after {
                push(.token(token), reply: index, force: force)
            }
            end(with: .finished(.complete), reply: index, force: force)
        case .failure(let failure):
            switch script.onFailure {
            case .failsReply:
                end(with: .failed(.engine(failure.description)), reply: index, force: force)
            case .speaks(let words):
                for token in words {
                    push(.token(token), reply: index, force: force)
                }
                end(with: .finished(.complete), reply: index, force: force)
            }
        }
    }

    /// One non-terminal update, guarded like `emit` — or forced.
    private func push(_ update: ReplyUpdate, reply index: Int, force: Bool) {
        let continuation = state.withLock { state in
            (force || !state.records[index].cancelled) ? state.continuations[index] : nil
        }
        continuation?.yield(update)
    }

    /// The terminal, guarded like `finish` — or forced. Either way the
    /// stream ends after it: one terminal, then nothing (the seam's promise).
    private func end(with update: ReplyUpdate, reply index: Int, force: Bool) {
        let continuation = state.withLock { state in
            (force || !state.records[index].cancelled)
                ? state.continuations.removeValue(forKey: index) : nil
        }
        continuation?.yield(update)
        continuation?.finish()
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
        let (continuation, toolRun) = state.withLock { state
            -> (AsyncStream<ReplyUpdate>.Continuation?, Task<Void, Never>?) in
            state.records[index].cancelled = true
            if ignoresCancel { return (nil, nil) }   // defiance: the stream stays open
            return (state.continuations.removeValue(forKey: index), state.toolRuns[index])
        }
        continuation?.finish()   // conformant: ends without a terminal update
        // The optimization, after the guarantee: a conformant tool run is
        // asked to stop wasting work. The flag above is what keeps its
        // answer out of the stream; this is only a courtesy to the tool.
        toolRun?.cancel()
    }
}

private struct ScriptedReply: ReplyRun {
    let generator: ScriptedReplyGenerator
    let index: Int
    let plan: ScriptedReplyGenerator.Plan
    let updates: AsyncStream<ReplyUpdate>

    func cancel() async {
        let ignores = switch plan {
        case .manual(let flag): flag
        case .callsTool(let script): script.ignoresCancel
        case .failOnOpen, .blockThenFailOnOpen: false
        }
        generator.cancel(reply: index, ignoresCancel: ignores)
    }
}
