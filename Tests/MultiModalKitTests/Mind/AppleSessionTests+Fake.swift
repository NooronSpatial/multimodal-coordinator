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

    /// How every session this maker makes answers a prompt: its cumulative
    /// snapshots, in order. The default names the prompt it answers, so a
    /// test can read the conversation back.
    let answer: @Sendable (String) -> [String]
    private let record = Mutex<[(made: Made, session: FakeSession)]>([])

    init(answer: @escaping @Sendable (String) -> [String] = { ["Answer to \($0)."] }) {
        self.answer = answer
    }

    var unavailable: MindUnavailable? { nil }

    /// Every making, oldest first, with what the session was born holding.
    var made: [Made] { record.withLock { $0.map(\.made) } }
    /// Every session made, oldest first — to read what each was asked.
    var sessions: [FakeSession] { record.withLock { $0.map(\.session) } }

    func makeSession(instructions: String?, tools: ToolTable,
                     seed: [ConversationTurn]) throws -> any MindSession {
        let session = FakeSession(answer: answer)
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

    let answer: @Sendable (String) -> [String]
    private let log = Mutex<[Asked]>([])

    init(answer: @escaping @Sendable (String) -> [String]) {
        self.answer = answer
    }

    var asked: [Asked] { log.withLock { $0 } }

    func respond(to prompt: String, tools: ToolTable,
                 options: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        log.withLock { $0.append(Asked(prompt: prompt, tools: tools, options: options)) }
        let snapshots = answer(prompt)
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
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
