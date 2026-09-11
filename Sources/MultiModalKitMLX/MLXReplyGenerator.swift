import Foundation
import MultiModalKit
import Synchronization

// MARK: - the internal seam (the D-053 rule, one seam over)

/// What one reply's TOKEN STREAM looks like — ours, so a test can make it
/// misbehave on command.
///
/// Internal on purpose, the same rule `ReplySnapshotStreaming` follows:
/// its second implementation is a test double, and public surface is
/// earned by a second REAL one.
///
/// Note what is NOT here. The Apple seam yields CUMULATIVE snapshots,
/// because that is the shape Apple's API has, and needs `SnapshotDiffer`
/// to turn them back into deltas. MLX emits tokens. This seam yields
/// deltas directly, which is the small piece of evidence SPEC §84 claims:
/// the second citizen fits the public seam more directly than the first.
///
/// The text arriving here is ALREADY gated — reasoning never becomes a
/// string, because only ids the `ThinkGate` admitted are ever detokenised
/// (§86 layer 2).
protocol ReplyTokenStreaming: Sendable {
    /// Why a generation cannot START, or nil. Asked at the door, every
    /// time: weights can finish downloading between two turns, so a
    /// cached refusal would freeze a temporary state into a verdict.
    /// TYPED since 4v (AC-238): the real source answers with
    /// `.unavailable(verdict)`, and the door throws exactly what it said.
    var unavailable: ReplyFailure? { get }
    /// The tools this source was given at construction (4w, F-2 = A).
    /// The RUN reads them to execute a call the source reports; the
    /// source reads them to render the spec into its prompt. One table,
    /// one owner — the generator's initializer hands it to both by
    /// handing it here.
    var tools: ToolTable { get }
    /// Opens one generation and returns its tokens, in birth order, and
    /// — when the vendor says — why it stopped.
    ///
    /// `exchanges` is every tool call this reply has ALREADY made, with
    /// what went back (4w, AC-222): empty on the first round, and one
    /// pair longer each time the run answers a call and asks again. The
    /// source renders them into the prompt after the question, in the
    /// template's own roles, so the model sees its call and the answer
    /// before it continues. A source that never reports a call never
    /// sees a non-empty list.
    func tokens(for context: ReplyContext,
                after exchanges: [ToolExchange]) -> AsyncThrowingStream<TokenEvent, any Error>
}

extension ReplyTokenStreaming {
    /// The first round, which every reply has and which is the whole of
    /// a reply that calls nothing.
    func tokens(for context: ReplyContext) -> AsyncThrowingStream<TokenEvent, any Error> {
        tokens(for: context, after: [])
    }
}

/// What the token seam carries (4v, D-103 F-2 = A). The vendor already
/// knows why a generation ended (`GenerateCompletionInfo.stopReason`) and
/// the source used to DROP that event; this enum is the room for it. A
/// stream that ends without `.stopped` means the source could not say.
///
/// `.toolCall` since 4w (AC-222): the source PARSED a call out of what
/// the model said, and hands it up flattened. It is not a terminal —
/// the round still ends with `.stopped`, because the model ends its turn
/// to make the call — and the run, not the source, decides what a call
/// means (F-1 = B: the run executes tools itself).
enum TokenEvent: Sendable, Equatable {
    case token(String)
    case toolCall(ToolCallRequest)
    case stopped(StopReason)
}

// MARK: - the generator

/// The mind seam's SECOND real citizen (SPEC 4h, D-062 F-1 = A).
///
/// One transcript in, a token stream out — the same two requirements the
/// Apple mind implements, and the same five conformance promises.
public struct MLXReplyGenerator: ReplyGenerating {
    let source: any ReplyTokenStreaming

    public func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        // At the door, every time — never cached.
        if let unavailable = source.unavailable { throw unavailable }
        return MLXReplyRun(source: source, context: context)
    }
}

// `MLXUnavailable` lived here until 4v — three sentences of this mind's
// own, one of which told a real phone it was the Simulator (D-101's
// F1). Its cases are `MindUnavailable`'s now, produced by the pure
// verdict over a `DeviceReport` (AC-238), and the door throws them as
// `ReplyFailure.unavailable`. The AC-110 lesson it recorded still holds
// and is kept there: a person whose device cannot host the runtime
// needs different words from one whose weights are not on disk yet.

// MARK: - one reply

/// ONE thought: tokens in, tokens out, exactly one terminal, and a dead
/// run stays dead.
///
/// The shape is `AppleReplyRun`'s deliberately — all state behind one
/// `Mutex`, nothing suspends under it, every terminal path through ONE
/// latch. A second citizen that invented a second shape would be a second
/// set of bugs, and the `retire()` doctrine exists because 4e's review
/// had to force this latch on after a run kept going past its own death.
final class MLXReplyRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let out: AsyncStream<ReplyUpdate>.Continuation

    private struct Guarded {
        var retired = false
    }
    private let state: Mutex<Guarded>
    /// The owned worker. Cancelling it is the OPTIMISATION; `retired` is
    /// the guarantee — the ticket doctrine, and the reason a defiant
    /// source cannot be heard after a cancel.
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(source: any ReplyTokenStreaming, context: ReplyContext) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.state = Mutex(Guarded())

        let task = Task { [weak self] in
            do {
                // THE ROUNDS (4w, F-1 = B). A reply that calls nothing is
                // one round, exactly as before 4w. A reply that calls a
                // tool is a round that ENDS with the call, the call
                // executed here, and another round asked for with the
                // answer in the prompt — until a round ends without a
                // call, or the cap says enough (`ToolRounds`).
                var exchanges: [ToolExchange] = []
                var rounds = 0
                while true {
                    // Re-acquired every round, never held across one: a
                    // run its owner dropped ends here, as it always has.
                    guard let self else { return }
                    guard let round = try await self.consume(
                        source.tokens(for: context, after: exchanges)) else { return }
                    // No call: the round was the reply. This is the ONLY
                    // `.finished` path, so a tool round's own `.stopped` —
                    // the model ending its turn to ask — is never spoken
                    // as the reply's end.
                    guard !round.calls.isEmpty else {
                        self.report(.finished(round.stop))
                        return
                    }
                    // THE CAP: a model that asks again after `cap` answered
                    // rounds is refused, typed, rather than spun.
                    guard rounds < ToolRounds.cap else {
                        self.report(.failed(ToolRounds.exceeded))
                        return
                    }
                    rounds += 1
                    guard let answered = await self.execute(round.calls, with: source.tools) else { return }
                    exchanges += answered
                }
            } catch let failure as ReplyFailure {
                // AC-236: a TYPED failure the source threw on purpose —
                // `.contextWindowExceeded`, refused before generation —
                // keeps its case. Wrapping it in `.engine(…)` would turn
                // a countable case back into prose.
                self?.report(.failed(failure))
            } catch {
                // The honest catch-all: anything the vendor throws is
                // `.engine(String)` — the words for a screen, the case for
                // a switch (F-3 = A).
                self?.report(.failed(.engine("local generation failed: \(error)")))
            }
        }
        work.withLock { $0 = task }
    }

    /// What one round of the source said: why it stopped, and the calls
    /// it asked for (none, before 4w and for every reply that calls
    /// nothing).
    private struct Round {
        var stop = StopReason.unreported
        var calls: [ToolCallRequest] = []
    }

    /// ONE ROUND: tokens spoken as they arrive, calls remembered, and the
    /// stop read. `nil` when the run died mid-round — the caller ends the
    /// task and nothing more is said or fed back.
    private func consume(
        _ stream: AsyncThrowingStream<TokenEvent, any Error>) async throws -> Round? {
        // `.unreported` until the source says otherwise — a stream
        // that ends without `.stopped` is an engine that could
        // not say (AC-235).
        var round = Round()
        for try await event in stream {
            guard case .token(let token) = event else {
                // `.stopped` is a TERMINAL on this seam too, the
                // same word it is one seam up: the FIRST reason is
                // the reason, and a token after it is the source
                // breaking its contract. The loop ends HERE, so
                // nothing later is admitted — the 4v review found
                // this loop still listening after the stop (a late
                // token was spoken; a second reason overwrote the
                // first). The only real source yields one
                // `.stopped` last; this pins the contract before a
                // second source can drift from it (AC-235).
                if case .stopped(let reason) = event { round.stop = reason }
                // A call is NOT a terminal: it is remembered, and
                // executed once the round has ended — the model
                // ends its turn to ask, and the vendor's `.info`
                // still follows. A dead run remembers nothing.
                if case .toolCall(let request) = event {
                    if state.withLock({ $0.retired }) { return nil }
                    round.calls.append(request)
                    continue
                }
                break
            }
            // Two guards keep a dead run silent, the same pair
            // `AppleReplyRun` documents: this flag re-read, AND
            // the stream having been finished by `cancel()` — a
            // finished AsyncStream drops every later yield. The
            // finish is the primary guard; the flag is the belt,
            // kept because the finish lives in another method.
            let admitted: String? = state.withLock { guarded in
                // An empty token is not silence to report — the
                // detokenizer yields "" while a multi-token
                // character is still incomplete.
                guard !guarded.retired, !token.isEmpty else { return nil }
                return token
            }
            guard let admitted else {
                if state.withLock({ $0.retired }) { return nil }
                continue
            }
            out.yield(.token(admitted))
        }
        return round
    }

    /// THE ARM (4w, AC-222; F-1 = B, F-4 = B): every call the round
    /// asked for, executed in order, and what goes back to the model.
    ///
    /// `ToolTable.call` folds both ways a call can fail — a name no tool
    /// has, a tool that threw — into one typed value, and BOTH are
    /// answered to the model as words (F-4 = B, D-101): the model reads
    /// "no tool named 'x'" as a tool response and recovers in its own
    /// sentence, which is the honest turn AC-225 wants. Reporting
    /// `.failed` instead was the rejected option A.
    ///
    /// THE REENTRANCY LAW (§4.1), after EVERY await: the tool took as long
    /// as it took, and a barge may have retired this run meanwhile. A
    /// dead run feeds NOTHING back — `nil` here ends the task, and the
    /// answer goes nowhere (AC-226's mirror on this seam: the scripted
    /// mind's `runToolScript` makes the same decision, and records it).
    /// The task's own cancellation is the optimisation that reaches into
    /// a slow tool; `retired` is the guarantee this guard reads.
    private func execute(_ calls: [ToolCallRequest],
                         with tools: ToolTable) async -> [ToolExchange]? {
        var answered: [ToolExchange] = []
        for request in calls {
            // Before AND after: a run retired between the round's last
            // event and this arm must not start a tool it can never use.
            guard !state.withLock({ $0.retired }) else { return nil }
            let outcome = await tools.call(request.name, arguments: request.arguments)
            guard !state.withLock({ $0.retired }) else { return nil }
            let answer = switch outcome {
            case .success(let words): words
            case .failure(let failure): failure.description
            }
            answered.append(ToolExchange(request: request, answer: answer))
        }
        return answered
    }

    /// EVERY terminal path ends here, and only the first one acts.
    ///
    /// MEASURED REDUNDANCY, recorded rather than dressed up: mutation
    /// removed this latch and NOT ONE test went red. The reason is
    /// structural — `report` cannot be called twice (the loop either
    /// completes or throws, never both), and in the cancel-then-finish
    /// race `out.finish()` has already run, and a finished AsyncStream
    /// drops every later yield. So the FINISH is the primary guard and
    /// this latch is the belt.
    ///
    /// It stays, for the reason the 4b precedent gives: redundancy is
    /// recorded, not pretended to be load-bearing. `AppleReplyRun` needed
    /// exactly this latch forced onto it by 4e's review after a failed
    /// decode kept running and aborted the process — the structure that
    /// masks it here is not guaranteed to survive the next change.
    private func report(_ terminal: ReplyUpdate) {
        let first = state.withLock { guarded -> Bool in
            let was = guarded.retired
            guarded.retired = true
            return !was
        }
        guard first else { return }
        out.yield(terminal)
        out.finish()
    }

    /// Waits for the worker to END — the fact a test needs before it can
    /// say what a cancelled run did NOT do (4w, the barge-during-a-call
    /// row): a negative read before the worker has decided is "not yet",
    /// not "never". Internal for `@testable`; a consumer has the stream.
    func awaitWorkerEnd() async {
        await work.withLock { $0 }?.value
    }

    /// Ends the stream with NO terminal — the seam's cancel contract.
    /// The flag is raised in the SAME locked step that decides "was I
    /// first", so a token in flight sees it before its next yield.
    func cancel() async {
        let first = state.withLock { guarded -> Bool in
            let was = guarded.retired
            guarded.retired = true
            return !was
        }
        work.withLock { $0 }?.cancel()
        guard first else { return }
        out.finish()
    }
}
