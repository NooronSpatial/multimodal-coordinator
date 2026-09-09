// The `determinism` instrument (4v, AC-234 / AC-244): the same question,
// asked twice under the same `GenerationOptions` — do the same bytes come
// back? Three settings, N runs each, on this Mac: the harness before the
// phone (the house rule). It also prices one whole reply — first token
// and total — which is what Aura's morning check-in will pay.
//
// Until the MLX piece honours `options` (AC-232..235) every setting is
// the vendor's default and the table SAYS so by its results; the
// instrument does not lie, it measures what the mind does today.
import Foundation
import MultiModalKit
import MultiModalKitMLX

// MARK: - determinism: ask twice, compare bytes

@MainActor
func runDeterminism(_ arguments: [String]) async {
    guard MLXRuntime.isAvailable else {
        print("no Metal shader library reachable, so MLX cannot be touched at all.")
        print("fix it with:  Scripts/metallib.sh")
        exit(2)
    }
    guard let weights = askDefaultWeights(arguments),
          FileManager.default.fileExists(atPath: weights.path) else {
        print("no weights found. pass --model=/path/to/Qwen3-4B-4bit")
        exit(2)
    }
    let model = LocalMindModel(weights: weights)
    // `--system=` and `--budget=` so this instrument can price the reply a
    // REAL caller asks for (4v, AC-244): Aura's slice 1 wants a session
    // proposal as JSON at the 1024-token budget, which is a different
    // price from a spoken sentence.
    let instructions = determinismArgument("--system=", in: arguments) ?? determinismInstructions
    let budget = determinismArgument("--budget=", in: arguments).flatMap(Int.init) ?? 160
    let mind = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: budget)
    let clock = ContinuousClock()
    await askLoadAndWarm(model: model, mind: mind, weights: weights, clock: clock)

    let prompt = determinismArgument("--prompt=", in: arguments)
        ?? "Name three capitals in Europe and one fact about each."
    let runs = determinismArgument("--runs=", in: arguments).flatMap(Int.init) ?? 2
    print("prompt: \(prompt)")
    print("budget: \(budget) tokens · instructions: \(instructions.prefix(60))…\n")
    print("| setting | run | first token | total | stop | chars | same bytes as run 1 |")
    print("|---|---|---|---|---|---|---|")
    for (name, options) in determinismSettings {
        var firstText: String?
        for run in 1...runs {
            let outcome = await determinismAsk(mind: mind, prompt: prompt, options: options, clock: clock)
            switch outcome {
            case .reply(let text, let stop, let firstToken, let total):
                let same = firstText.map { $0 == text ? "yes" : "NO" } ?? "—"
                if firstText == nil { firstText = text }
                print("| \(name) | \(run) | \(determinismMs(firstToken)) ms | \(determinismMs(total)) ms "
                      + "| \(stop) | \(text.count) | \(same) |")
            case .failed(let why):
                print("| \(name) | \(run) | failed: \(why) | | | | |")
            }
        }
        if let firstText { print("\n  run 1 said: \(firstText.prefix(160))\n") }
    }
    exit(0)
}

// MARK: - the three settings the spec names (AC-234)

private let determinismSettings: [(String, GenerationOptions)] = [
    ("greedy — temperature 0", GenerationOptions(temperature: 0)),
    ("seeded — seed 7, temperature 0.6", GenerationOptions(temperature: 0.6, seed: 7)),
    ("free — the vendor's defaults", GenerationOptions())
]

private let determinismInstructions = "Answer in two or three short sentences of plain prose. "
    + "No lists, no markdown."

// MARK: - one whole reply, timed by hand so the first token is seen

private enum DeterminismOutcome {
    case reply(text: String, stop: StopReason, firstToken: Duration, total: Duration)
    case failed(String)
}

/// `reply(to:)` hides the first token's arrival; AC-244 wants it priced.
/// So the run is drained here the way the whole-reply helper drains it,
/// with one clock read on the first token.
@MainActor
private func determinismAsk(mind: MLXReplyGenerator, prompt: String,
                            options: GenerationOptions, clock: ContinuousClock) async -> DeterminismOutcome {
    let start = clock.now
    var firstToken: Duration?
    var text = ""
    do {
        let run = try await mind.openReply(to: ReplyContext(transcript: prompt, options: options))
        for await update in run.updates {
            switch update {
            case .token(let token):
                if firstToken == nil { firstToken = start.duration(to: clock.now) }
                text += token
            case .finished(let stop):
                return .reply(text: text, stop: stop,
                              firstToken: firstToken ?? .zero, total: start.duration(to: clock.now))
            case .failed(let failure):
                return .failed(failure.description)
            }
        }
        return .failed("the reply ended without a terminal")
    } catch {
        return .failed("\(error)")
    }
}

private func determinismArgument(_ prefix: String, in arguments: [String]) -> String? {
    arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

private func determinismMs(_ duration: Duration) -> Int {
    Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15)
}
