import Foundation
import MultiModalKit
import Synchronization

// The demo-tier stages that sit behind the library's seams: the latency
// reporter, the paced echo mind, and the `Duration` formatting they print.

// MARK: - Phase 4a demo-tier stages (D-016 liberties: real clocks, an
// unstructured task per reply — never taken in the library or its tests)

/// Wall-clock latency to the terminal (R2). Demo-tier liberty: the report
/// hops to the screen actor via an unstructured task (D-016).
struct ConsoleLatency: LatencyReporter {
    let screen: Screen
    func turnLatency(_ duration: Duration, turn: Int) {
        let screen = screen
        Task { await screen.log("⏱  [\(turn)] felt pause: \(duration.formattedMs)") }
    }
    func cancelLatency(_ duration: Duration, turn: Int) {
        let screen = screen
        Task { await screen.log("⏱  [\(turn)] barge → dead in \(duration.formattedMs)") }
    }
}

extension Duration {
    var formattedMs: String {
        let ms = Double(components.seconds) * 1000
            + Double(components.attoseconds) * 1e-15
        return String(format: "%.0f ms", ms)
    }
}

/// Echoes the user's words back, one token at a time, paced so the reply
/// FEELS generated — slow enough to barge into. Tokens carry their own
/// spacing (the way real generators emit them): the phraser concatenates
/// VERBATIM and never invents a space.
struct PacedEchoReply: ReplyGenerating {
    let screen: Screen

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        let transcript = context.transcript
        // AC-91: the milestone made visible. This prints what actually
        // CROSSED THE SEAM — the generator's own view, which is the only
        // honest witness that the whole thought arrived. Speak two
        // sentences with a pause and this line holds both.
        await screen.log("🧠 whole thought → \"\(transcript)\"")
        return EchoRun(words: ["You", " said:"]
            + transcript.split(separator: " ").map { " " + $0 })
    }
}

private final class EchoRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(words: [String]) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        let out = handle!
        task.withLock { $0 = Task {
            for word in words {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { out.finish(); return }   // conformant:
                out.yield(.token(word))                                 // no terminal
            }
            out.yield(.finished)
            out.finish()
        } }
    }

    func cancel() async { task.withLock { $0?.cancel() } }
}

// (The 4a `TerminalVoice` — a mouth that only printed — retired here: the
// real `AppleSpeechSynthesizer` speaks behind the same seam, which was
// the seam's whole promise. Its contract lives on in the library's
// `ScriptedSynthesizer`, where the deterministic tests need it.)
