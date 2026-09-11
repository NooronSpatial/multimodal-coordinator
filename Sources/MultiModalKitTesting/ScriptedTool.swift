import MultiModalKit
import Synchronization

/// A tool under the test's thumb (4w, AC-221/AC-224..226): it answers,
/// it throws, or it PARKS until the test says go — the three shapes the
/// spike's survival tests need, and the way a test proves a call was
/// made with the arguments the script gave.
///
/// The run calls `tool.call` from inside itself (F-1 = B). What the test
/// does with that moment is its own: `onEnter` fires with the arguments
/// as the call begins, so a test can wait on the FACT "the tool was
/// entered" instead of a delay (§3.3), and `release()` lets a parked
/// call out — safe to call before anyone is waiting, the release is
/// remembered (the same rule as `ScriptedReplyGenerator.releaseOpen`).
public final class ScriptedTool: Sendable {
    public indirect enum Plan: Sendable {
        /// Returns this string.
        case answers(String)
        /// Throws, with these words as the error's description.
        case throwsError(String)
        /// Suspends until `release()`, then behaves like `then`. The SLOW
        /// tool of AC-224 and the in-flight call of AC-226.
        case waitsForRelease(then: Plan)
    }

    /// What a scripted throw looks like from the run: its words, verbatim,
    /// so `ToolCallFailure.threw` carries exactly what the test scripted.
    public struct ScriptedError: Error, CustomStringConvertible {
        public let description: String
    }

    private struct State {
        var calls: [[String: String]] = []
        var gate: CheckedContinuation<Void, Never>?
        var releasedEarly = false
    }

    public let name: String
    public let plan: Plan
    private let onEnter: @Sendable ([String: String]) -> Void
    private let state = Mutex(State())

    public init(name: String, plan: Plan,
                onEnter: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        self.name = name
        self.plan = plan
        self.onEnter = onEnter
    }

    // MARK: - the record

    /// Every call, with the arguments it was made with, in order.
    public var calls: [[String: String]] { state.withLock { $0.calls } }

    // MARK: - the test's hand

    /// Lets a `waitsForRelease` call out. Remembered if nobody waits yet.
    public func release() {
        // Snapshot under the lock, resume OUTSIDE it (§4.1's second rule).
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.releasedEarly = true
            return state.gate.take()
        }
        waiting?.resume()
    }

    // MARK: - the tool the generator is handed

    /// The library-facing value (F-2 = A): put it in the `ToolTable` the
    /// scripted generator is built with.
    public var tool: ReplyTool {
        ReplyTool(name: name, description: "a scripted tool named \(name)") { [self] arguments in
            state.withLock { $0.calls.append(arguments) }
            onEnter(arguments)
            return try await self.run(plan, arguments: arguments)
        }
    }

    private func run(_ plan: Plan, arguments: [String: String]) async throws -> String {
        switch plan {
        case .answers(let answer):
            return answer
        case .throwsError(let words):
            throw ScriptedError(description: words)
        case .waitsForRelease(let then):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let releaseNow = state.withLock { state -> Bool in
                    if state.releasedEarly { return true }
                    state.gate = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
            return try await run(then, arguments: arguments)
        }
    }
}

// MARK: - the script and the record

/// What a `ScriptedReplyGenerator.Plan.callsTool` reply does, in order:
/// says `before`, calls `name` with `arguments`, says the answer as ONE
/// token, says `after`, and finishes `.complete`. When the call fails
/// the script picks one of F-4's two honest endings (`onFailure`).
public struct ToolScript: Sendable {
    /// What the run does when the tool throws or the name has no tool
    /// (AC-225). Both are honest; the coordinator sees a different
    /// terminal for each.
    public enum OnFailure: Sendable {
        /// The run gives up: `.failed(.engine(failure.description))`.
        case failsReply
        /// F-4 = B: the mind is told and recovers IN WORDS — these
        /// tokens, then `.finished(.complete)`.
        case speaks([String])
    }

    public var name: String
    public var arguments: [String: String]
    public var before: [String]
    public var after: [String]
    public var onFailure: OnFailure
    /// The DEFIANT flag, same meaning as `.manual(ignoresCancel:)`:
    /// `cancel()` is recorded but the run keeps going, so a tool's
    /// late answer is pushed into a dead turn as a real ghost. Proof
    /// duty for AC-226 — the ticket, not the run, must discard it.
    public var ignoresCancel: Bool
    /// Called once the run has pushed its LAST update — the event a
    /// test waits on to know the ghost (or the dropped answer) has
    /// been emitted, rather than hoping it was (§3.3).
    public var whenDone: @Sendable () -> Void

    public init(name: String,
                arguments: [String: String] = [:],
                before: [String] = [],
                after: [String] = [],
                onFailure: OnFailure = .failsReply,
                ignoresCancel: Bool = false,
                whenDone: @escaping @Sendable () -> Void = {}) {
        self.name = name
        self.arguments = arguments
        self.before = before
        self.after = after
        self.onFailure = onFailure
        self.ignoresCancel = ignoresCancel
        self.whenDone = whenDone
    }
}

/// One tool call the run made, and how it ended — the typed,
/// countable record AC-225 asks for, on the side that made the call.
public struct ToolCallRecord: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case answered(String)
        case failed(ToolCallFailure)
    }

    public let name: String
    public let arguments: [String: String]
    /// `nil` while the call is still in flight.
    public var outcome: Outcome?
    /// True when the answer came back AFTER `cancel()` and a
    /// conformant run dropped it — the run's own half of AC-226; the
    /// coordinator's ticket is the other half, and the guarantee.
    public var answerDropped = false

    public init(name: String, arguments: [String: String],
                outcome: Outcome? = nil, answerDropped: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.outcome = outcome
        self.answerDropped = answerDropped
    }
}
