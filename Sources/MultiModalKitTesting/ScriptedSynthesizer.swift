import MultiModalKit
import Synchronization

/// A speech synthesizer under the test's thumb — the mouth that only moves
/// when told to, and (defiantly) sometimes when told not to.
///
/// Plans mirror `ScriptedReplyGenerator`: `.manual` is conformant,
/// `.manual(ignoresCancel: true)` keeps the stream open after cancel so
/// `forceUpdate` can report a ghost `started`/`finished` into a dead turn.
public final class ScriptedSynthesizer: SpeechSynthesizing, Sendable {
    public enum Plan: Sendable {
        case manual(ignoresCancel: Bool = false)
        case failOnOpen(String)
    }

    public struct UtteranceRecord: Sendable {
        public var fedTokens: [String] = []
        public var tokensFinished = false
        public var cancelled = false
    }

    private struct State {
        var records: [UtteranceRecord] = []
        var continuations: [Int: AsyncStream<SynthesisUpdate>.Continuation] = [:]
    }

    private let plans: [Plan]
    private let state = Mutex(State())

    public init(plans: [Plan]) {
        self.plans = plans
    }

    public static func manual(utterances: Int) -> ScriptedSynthesizer {
        ScriptedSynthesizer(plans: Array(repeating: .manual(), count: utterances))
    }

    // MARK: - the record

    public var utterancesOpened: Int { state.withLock { $0.records.count } }

    public func record(ofUtterance index: Int) -> UtteranceRecord? {
        state.withLock { index < $0.records.count ? $0.records[index] : nil }
    }

    // MARK: - the test's hands (conformant: guarded by !cancelled)

    public func reportStarted(utterance index: Int) {
        report(index, .started, terminal: false)
    }

    public func reportFinished(utterance index: Int) {
        report(index, .finished, terminal: true)
    }

    public func reportFailed(utterance index: Int, reason: String) {
        report(index, .failed(reason), terminal: true)
    }

    private func report(_ index: Int, _ update: SynthesisUpdate, terminal: Bool) {
        let continuation = state.withLock { state -> AsyncStream<SynthesisUpdate>.Continuation? in
            guard index < state.records.count, !state.records[index].cancelled else { return nil }
            return terminal ? state.continuations.removeValue(forKey: index)
                            : state.continuations[index]
        }
        continuation?.yield(update)
        if terminal { continuation?.finish() }
    }

    // MARK: - the defiant hand

    /// Reports RIGHT NOW, cancelled or not — the ghost's mouth.
    public func forceUpdate(utterance index: Int, _ update: SynthesisUpdate) {
        state.withLock { $0.continuations[index] }?.yield(update)
    }

    // MARK: - SpeechSynthesizing

    public func openUtterance() async throws -> any SynthesisRun {
        // Record and continuation in ONE lock — see ScriptedReplyGenerator:
        // an observer that can see the record must be able to reach the
        // stream, or reports race into nothing.
        var handle: AsyncStream<SynthesisUpdate>.Continuation!
        let stream = AsyncStream<SynthesisUpdate> { handle = $0 }
        let continuation = handle!
        let (index, plan) = state.withLock { state -> (Int, Plan) in
            state.records.append(UtteranceRecord())
            let index = state.records.count - 1
            let plan = index < plans.count ? plans[index] : Plan.manual()
            if case .failOnOpen = plan {} else {
                state.continuations[index] = continuation
            }
            return (index, plan)
        }

        if case .failOnOpen(let reason) = plan {
            throw TurnFailure.synthesisFailed(reason)
        }
        return ScriptedUtterance(synthesizer: self, index: index, plan: plan, updates: stream)
    }

    fileprivate func feed(utterance index: Int, token: String) {
        state.withLock { $0.records[index].fedTokens.append(token) }
    }

    fileprivate func finishTokens(utterance index: Int) {
        state.withLock { $0.records[index].tokensFinished = true }
    }

    fileprivate func cancel(utterance index: Int, ignoresCancel: Bool) {
        let continuation = state.withLock {
            state -> AsyncStream<SynthesisUpdate>.Continuation? in
            state.records[index].cancelled = true
            if ignoresCancel { return nil }
            return state.continuations.removeValue(forKey: index)
        }
        continuation?.finish()
    }
}

private struct ScriptedUtterance: SynthesisRun {
    let synthesizer: ScriptedSynthesizer
    let index: Int
    let plan: ScriptedSynthesizer.Plan
    let updates: AsyncStream<SynthesisUpdate>

    func feed(_ token: String) async { synthesizer.feed(utterance: index, token: token) }
    func finishTokens() async { synthesizer.finishTokens(utterance: index) }
    func cancel() async {
        let ignores = if case .manual(let flag) = plan { flag } else { false }
        synthesizer.cancel(utterance: index, ignoresCancel: ignores)
    }
}
