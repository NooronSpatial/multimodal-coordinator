// The `ask` instrument: a real conversation with the second mind on this
// Mac, and the log it writes after every turn.
import Foundation
import MultiModalKitMLX

// MARK: - ask: talk to the second mind on this Mac

/// The Mac's way of USING the second mind rather than measuring it.
///
///   swift run bakeoff ask "what is the capital of italy?"   one question
///   swift run bakeoff ask                                   keep asking
///
/// The weights default to the Hugging Face cache, so there is nothing to
/// type on a machine that already has them. Tokens print AS THEY ARRIVE,
/// which is the seam's whole point made visible: the mouth would be
/// speaking these before the sentence exists.
@MainActor
func runAsk(_ arguments: [String]) async {
    guard MLXRuntime.isAvailable else {
        print("no Metal shader library reachable, so MLX cannot be touched at all.")
        print("MLX ABORTS the process rather than failing (D-061), so this stops here.")
        print("fix it with:  Scripts/metallib.sh")
        exit(2)
    }
    guard let weights = askDefaultWeights(arguments),
          FileManager.default.fileExists(atPath: weights.path) else {
        print("no weights found. pass --model=/path/to/Qwen3-0.6B-4bit")
        exit(2)
    }

    let model = LocalMindModel(weights: weights)
    let mind = askMakeMind(arguments, model: model)

    let clock = ContinuousClock()
    await askLoadAndWarm(model: model, mind: mind, weights: weights, clock: clock)

    // THE LOG, so a Mac session can be shared the same way the phone's
    // can. Written after every turn rather than at exit: the turn worth
    // sharing is often the one before something hangs.
    let logURL = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "mind-log.md")
    let session = AskSession(mind: mind, clock: clock, logURL: logURL, weights: weights)

    // One question on the command line, or keep asking until ctrl-D.
    let asked = arguments.dropFirst(2).filter { !$0.hasPrefix("--") }
    if !asked.isEmpty {
        await session.answer(asked.joined(separator: " "))
        exit(0)
    }
    print("type a question, or ctrl-D to stop.")
    while true {
        FileHandle.standardOutput.write(Data("> ".utf8))
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty
        else { break }
        await session.answer(line)
    }
    print("bye. log written to \(logURL.path)")
    exit(0)
}

@MainActor
private func askDefaultWeights(_ arguments: [String]) -> URL? {
    if let given = arguments.first(where: { $0.hasPrefix("--model=") }) {
        return URL(filePath: String(given.dropFirst("--model=".count)))
    }
    let cache = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: cache, includingPropertiesForKeys: nil) else { return nil }
    return entries.first
}

@MainActor
private func askMakeMind(_ arguments: [String], model: LocalMindModel) -> MLXReplyGenerator {
    MLXReplyGenerator(
        model: model,
        // WORD FOR WORD the demo's text by default, so this tool
        // reproduces the phone rather than approximating it — a field
        // report cannot be chased with a different prompt than the one
        // that produced it. `--system=` overrides it so a candidate fix
        // can be MEASURED against the same inputs before anyone ships it.
        instructions: arguments.first(where: { $0.hasPrefix("--system=") })
            .map { String($0.dropFirst("--system=".count)) }
            ?? "Your reply will be spoken aloud by a synthetic voice "
            + "and never shown as text. Answer in ONE short sentence. Do not "
            + "add extra facts, background or explanation unless the person "
            + "asks for them. Never use lists, bullet points, numbered items, "
            + "markdown, code, or headings.",
        maxTokens: 160)
}

@MainActor
private func askLoadAndWarm(model: LocalMindModel, mind: MLXReplyGenerator,
                            weights: URL, clock: ContinuousClock) async {
    let loadStart = clock.now
    print("loading \(weights.lastPathComponent)…")
    do { _ = try await model.ensureModel() } catch {
        print("could not load the model: \(error)"); exit(2)
    }
    // LOADING IS NOT WARMING (INSTRUMENTS §25) — burn the pipeline cost
    // here, so the first real question is as fast as the second.
    if let warm = try? await mind.openReply(to: "hi") {
        for await _ in warm.updates { break }
        await warm.cancel()
    }
    let ready = loadStart.duration(to: clock.now)
    print(String(format: "MLX memory: active %d MB · peak %d MB (RESIDENT — MLX does not mmap)",
                 MLXRuntime.activeMemoryBytes / 1_048_576,
                 MLXRuntime.peakMemoryBytes / 1_048_576))
    print(String(format: "ready in %.1f s · everything below runs on this Mac, offline\n",
                 Double(ready.components.seconds)
                     + Double(ready.components.attoseconds) * 1e-18))
}

/// One `ask` session: the mind under the questions, the clock that times
/// them, and the log written after every turn.
@MainActor
private final class AskSession {
    let mind: MLXReplyGenerator
    let clock: ContinuousClock
    let logURL: URL
    var log: String

    init(mind: MLXReplyGenerator, clock: ContinuousClock, logURL: URL, weights: URL) {
        self.mind = mind
        self.clock = clock
        self.logURL = logURL
        var log = "# Conversation log — bakeoff ask (Mac)\n\n"
        log += "model: \(weights.lastPathComponent)\nmind: Local (MLX)\n\n"
        self.log = log
    }

    func answer(_ question: String) async {
        let start = clock.now
        var first: Duration?
        var pieces = 0
        var said = ""
        do {
            let reply = try await mind.openReply(to: question)
            for await update in reply.updates {
                switch update {
                case .token(let piece):
                    if first == nil { first = start.duration(to: clock.now) }
                    pieces += 1
                    said += piece
                    FileHandle.standardOutput.write(Data(piece.utf8))   // AS IT ARRIVES
                case .failed(let why): print("\n  ✗ \(why)")
                case .finished: break
                }
            }
        } catch {
            print("  ✗ refused at the door: \(error)")
            return
        }
        let ms = { (duration: Duration) in
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) * 1e-15
        }
        let total = start.duration(to: clock.now)
        let after = max(ms(total) - ms(first ?? total), 0.001)
        print(String(format: "\n   [first word %.0f ms · %d pieces · %.0f/s]\n",
                     ms(first ?? total), pieces,
                     Double(max(pieces - 1, 0)) / (after / 1000)))
        log += "## \(question)\n\n\(said.isEmpty ? "_(no words)_" : said)\n\n"
        log += String(format: "first word %.0f ms · %d pieces\n\n",
                      ms(first ?? total), pieces)
        try? Data(log.utf8).write(to: logURL)
    }
}
