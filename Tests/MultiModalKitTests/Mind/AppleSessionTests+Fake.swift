// The doubles `AppleSessionTests` drives: the FAKE SESSION MAKER — SPEC
// §210's instrument, standing in for the Apple model on a machine where
// it reports `modelNotReady` — and a mouth that speaks at once.

import Synchronization
@testable import MultiModalKit

/// Makes `FakeSession`s and writes down every making: what each session
/// was born holding. A count of makings IS the count of full prefills —
/// the instructions, the tool schemas and the past, paid again — which is
/// the number 5b exists to bring to one per conversation.
final class FakeSessionMaker: MindSessionMaking {
    struct Made: Equatable, Sendable {
        let instructions: String?
        let tools: ToolTable
        let seed: [ConversationTurn]
    }

    /// How every session this maker makes answers a prompt. The default
    /// names the prompt it answers, so a test can read the conversation
    /// back.
    let script: @Sendable (String) -> FakeSession.Plan
    /// Where a session announces "asked:<prompt>" — the EVENT a test waits
    /// on before it cuts an answer, never a guess about timing.
    let signals: ToolSpikeTests.Signals?
    private let record = Mutex<[(made: Made, session: FakeSession)]>([])

    init(signals: ToolSpikeTests.Signals? = nil,
         script: @escaping @Sendable (String) -> FakeSession.Plan = { .answers(["Answer to \($0)."]) }) {
        self.signals = signals
        self.script = script
    }

    var unavailable: MindUnavailable? { nil }

    /// Every making, oldest first, with what the session was born holding.
    var made: [Made] { record.withLock { $0.map(\.made) } }
    /// Every session made, oldest first — to read what each was asked.
    var sessions: [FakeSession] { record.withLock { $0.map(\.session) } }

    func makeSession(instructions: String?, tools: ToolTable,
                     seed: [ConversationTurn]) throws -> any MindSession {
        let session = FakeSession(script: script, signals: signals)
        record.withLock {
            $0.append((Made(instructions: instructions, tools: tools, seed: seed), session))
        }
        return session
    }
}

/// One fake session: writes down every prompt it is asked — with the
/// table and the options that came with it — and answers from the script.
/// What it was asked is ALL the model would have been sent on that turn:
/// the protocol has no other door.
final class FakeSession: MindSession {
    struct Asked: Equatable, Sendable {
        let prompt: String
        let tools: ToolTable
        let options: GenerationOptions
    }

    enum Plan: Sendable {
        /// These cumulative snapshots, then the answer ends on its own.
        case answers([String])
        /// These updates in order — snapshots and tool uses — then the
        /// answer ends on its own. What a real session streams when the
        /// model uses a tool (5b piece 2).
        case steps([MindSessionUpdate])
        /// Nothing, until the listener goes away — an answer a barge or a
        /// deadline will cut before its first word. It never finishes on
        /// its own, so it can never be mistaken for a finished answer.
        case holdsUntilCut
    }

    let script: @Sendable (String) -> Plan
    let signals: ToolSpikeTests.Signals?
    private let log = Mutex<[Asked]>([])
    /// A held answer's continuation, KEPT so the stream stays open until
    /// its reader is cancelled — never ended early by being dropped.
    private let held = Mutex<[AsyncThrowingStream<MindSessionUpdate, any Error>.Continuation]>([])

    init(script: @escaping @Sendable (String) -> Plan, signals: ToolSpikeTests.Signals?) {
        self.script = script
        self.signals = signals
    }

    var asked: [Asked] { log.withLock { $0 } }

    func respond(to prompt: String, tools: ToolTable,
                 options: GenerationOptions) -> AsyncThrowingStream<MindSessionUpdate, any Error> {
        log.withLock { $0.append(Asked(prompt: prompt, tools: tools, options: options)) }
        let plan = script(prompt)
        let stream = AsyncThrowingStream<MindSessionUpdate, any Error> { continuation in
            switch plan {
            case .answers(let snapshots):
                for snapshot in snapshots { continuation.yield(.snapshot(snapshot)) }
                continuation.finish()
            case .steps(let updates):
                for update in updates { continuation.yield(update) }
                continuation.finish()
            case .holdsUntilCut:
                // Held open; the stream ends when its reader is cancelled
                // (`AsyncThrowingStream` finishes a cancelled `next()`).
                self.held.withLock { $0.append(continuation) }
            }
        }
        signals?.send("asked:\(prompt)")
        return stream
    }
}

/// A mouth that speaks at once: `started` with the first token, `finished`
/// when the tokens end. The coordinator rows here are about the MIND; a
/// mouth the test had to drive by hand would only add waits.
final class InstantMouth: SpeechSynthesizing {
    func openUtterance() async throws -> any SynthesisRun { InstantUtterance() }
}

final class InstantUtterance: SynthesisRun {
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation
    private let spoke = Mutex(false)

    init() {
        (updates, out) = AsyncStream.makeStream(of: SynthesisUpdate.self)
    }

    func feed(_ token: String) async {
        let first = spoke.withLock { spoke -> Bool in
            defer { spoke = true }
            return !spoke
        }
        if first { out.yield(.started) }
    }

    func finishTokens() async {
        out.yield(.finished)
        out.finish()
    }

    func cancel() async { out.finish() }
}

/// The coordinator with its real memory, a mind under test and a mouth
/// that speaks at once — driven by EVENTS: `say` returns when the turn's
/// `completed` was heard, never after a guess about time.
struct CoordinatorRig {
    let coordinator: TurnCoordinator<ContinuousClock>
    let signals = ToolSpikeTests.Signals()
    private let listener: Broadcast<TurnEvent>.Listener
    private let audio: AsyncStream<AudioEvent>
    private let audioIn: AsyncStream<AudioEvent>.Continuation
    private let transcripts: AsyncStream<TranscriptEvent>
    private let transcriptsIn: AsyncStream<TranscriptEvent>.Continuation

    /// Memory bounds wide open unless a row is about the bound.
    init(mind: any ReplyGenerating, maxMemoryTurns: Int = 64, maxMemoryCharacters: Int = 64_000) async throws {
        coordinator = try TurnCoordinator(
            replyGenerator: mind, synthesizer: InstantMouth(),
            config: .init(maxMemoryTurns: maxMemoryTurns, maxMemoryCharacters: maxMemoryCharacters))
        listener = await coordinator.listen()
        (audio, audioIn) = AsyncStream.makeStream(of: AudioEvent.self)
        (transcripts, transcriptsIn) = AsyncStream.makeStream(of: TranscriptEvent.self)
    }

    /// The loop and the event forwarder, as children of the test's group.
    func start(in group: inout TaskGroup<Void>) {
        let coordinator = coordinator, audio = audio, transcripts = transcripts
        let listener = listener, signals = signals
        group.addTask { await coordinator.run(audio: audio, transcripts: transcripts) }
        group.addTask {
            for await event in listener.events { signals.send(ToolSpikeTests.name(of: event)) }
        }
    }

    /// One utterance — its onset, then its final — and the wait for its
    /// turn to complete. Utterance `n` is turn `n` while no turn barges.
    func say(_ text: String, utterance: Int) async -> Bool {
        let frames = utterance * 96_000
        audioIn.yield(.speechStarted(utterance: utterance, at: TurnCoordinatorTests.t(frames)))
        transcriptsIn.yield(.final(text, utterance: utterance, at: TurnCoordinatorTests.t(frames + 960)))
        return await signals.heard("completed:\(utterance)")
    }

    /// The inputs end and the loop stops; the group then drains.
    func end() async {
        audioIn.finish()
        transcriptsIn.finish()
        await coordinator.stop()
    }
}
