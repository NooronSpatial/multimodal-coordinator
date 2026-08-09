import Synchronization

/// A transcription engine that does exactly what its script says — including
/// the wrong thing, on purpose (test support for SPEC AC-25, AC-29).
///
/// Plans, one per run the session opens:
/// - `.normal(partialEveryChunks:)` — a partial after every N fed chunks
///   ("u0:p1", "u0:p2", …), and on `finishAudio()` exactly one final
///   ("u0:final(6 chunks)"). The well-behaved engine.
/// - `.silent` — never answers, and IGNORES `cancel()`: its stream stays open
///   so a test can force a LATE final into a dead utterance with
///   `forceFinal(run:text:)`. The defiant engine — proof duty for the ticket.
/// - `.failOnOpen` — `openRun` itself throws (no model, bad format).
/// - `.failWhileRunning(afterChunks:)` — behaves, then dies mid-utterance
///   with the exact failure shape observed in the SpeechAnalyzer spike.
///
/// Everything is recorded: how many runs were opened, every chunk each run
/// was fed, whether it was told to finish or cancel. Tests assert against
/// the record, not against hope.
public final class ScriptedTranscriber: TranscriptionEngine, Sendable {
    public enum RunPlan: Sendable {
        case normal(partialEveryChunks: Int)
        case silent
        case failOnOpen(TranscriptionFailure)
        case failWhileRunning(afterChunks: Int, TranscriptionFailure)
    }

    public struct RunRecord: Sendable {
        public var fedChunks: [AudioChunk] = []
        public var audioFinished = false
        public var cancelled = false
        public var emittedFinal = false
    }

    private struct State {
        var nextRun = 0
        var records: [RunRecord] = []
        var continuations: [Int: AsyncStream<TranscriptionUpdate>.Continuation] = [:]
    }

    public let capabilities = EngineCapabilities(emitsPartials: true)

    private let plans: [RunPlan]
    private let state = Mutex(State())

    public init(plans: [RunPlan]) {
        self.plans = plans
    }

    // MARK: - the record, for assertions

    public var runsOpened: Int { state.withLock { $0.records.count } }

    public func record(ofRun index: Int) -> RunRecord? {
        state.withLock { index < $0.records.count ? $0.records[index] : nil }
    }

    /// The defiant move: deliver a final into a run RIGHT NOW, no matter how
    /// long ago it ended. If the session publishes this, the ticket failed.
    public func forceFinal(run index: Int, text: String) {
        let continuation = state.withLock { $0.continuations[index] }
        continuation?.yield(.final(text))
    }

    // MARK: - TranscriptionEngine

    public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun {
        let index = state.withLock { state -> Int in
            let index = state.nextRun
            state.nextRun += 1
            return index
        }
        let plan = index < plans.count ? plans[index] : .normal(partialEveryChunks: 2)

        if case .failOnOpen(let failure) = plan {
            state.withLock { $0.records.append(RunRecord()) }
            throw failure
        }

        var handle: AsyncStream<TranscriptionUpdate>.Continuation!
        let stream = AsyncStream<TranscriptionUpdate> { handle = $0 }
        state.withLock { state in
            state.records.append(RunRecord())
            state.continuations[index] = handle
        }
        return ScriptedRun(engine: self, index: index, updates: stream)
    }

    // MARK: - the run's callbacks (all decided under one lock, yielded outside)

    fileprivate func feed(run index: Int, chunk: AudioChunk) {
        enum Verdict { case partial(String), fail(TranscriptionFailure), nothing }
        let (verdict, continuation) = state.withLock {
            state -> (Verdict, AsyncStream<TranscriptionUpdate>.Continuation?) in
            state.records[index].fedChunks.append(chunk)
            let count = state.records[index].fedChunks.count
            let continuation = state.continuations[index]

            switch planFor(index) {
            case .normal(let every) where count % every == 0:
                return (.partial("u\(index):p\(count / every)"), continuation)
            case .failWhileRunning(let after, let failure) where count == after:
                return (.fail(failure), continuation)
            default:
                return (.nothing, continuation)
            }
        }
        switch verdict {
        case .partial(let text): continuation?.yield(.partial(text))
        case .fail(let failure):
            continuation?.yield(.failed(failure))
            continuation?.finish()
        case .nothing: break
        }
    }

    fileprivate func finishAudio(run index: Int) {
        let (final, continuation) = state.withLock {
            state -> (String?, AsyncStream<TranscriptionUpdate>.Continuation?) in
            state.records[index].audioFinished = true
            guard case .normal = planFor(index), !state.records[index].emittedFinal else {
                return (nil, nil)   // silent stays silent; dead stays dead
            }
            state.records[index].emittedFinal = true
            let count = state.records[index].fedChunks.count
            return ("u\(index):final(\(count) chunks)", state.continuations[index])
        }
        if let final {
            continuation?.yield(.final(final))
            continuation?.finish()
        }
    }

    fileprivate func cancel(run index: Int) {
        let continuation = state.withLock {
            state -> AsyncStream<TranscriptionUpdate>.Continuation? in
            state.records[index].cancelled = true
            if case .silent = planFor(index) { return nil }   // defiance: ignore it
            return state.continuations[index]
        }
        continuation?.finish()   // a conformant engine ends the stream, no final
    }

    private func planFor(_ index: Int) -> RunPlan {
        index < plans.count ? plans[index] : .normal(partialEveryChunks: 2)
    }
}

private struct ScriptedRun: TranscriptionRun {
    let engine: ScriptedTranscriber
    let index: Int
    let updates: AsyncStream<TranscriptionUpdate>

    func feed(_ chunk: AudioChunk) async { engine.feed(run: index, chunk: chunk) }
    func finishAudio() async { engine.finishAudio(run: index) }
    func cancel() async { engine.cancel(run: index) }
}
