// The `tool-contract` instrument (4z, AC-276 — the Mac half): what the
// parameters cost in the prompt, and whether the model passes the number
// the person said. The harness before the phone (the house rule, §172c):
// the phone's rows are Ryad's gate; nothing printed here claims them.
// The 4B — the phone's own model — is in this Mac's cache, so
// `--model=` the 4B is the closest a Mac gets to the phone's answer.
//
// TWO MEASUREMENTS, TWO QUESTIONS:
//
//   1. THE SPEC'S PRICE (AC-276 a). A question that needs no tool, asked
//      against no table, the spike's one-tool table (no parameters), and
//      a three-tool table with parameters — Emberleaf's first verbs. The
//      spec's rendered characters and the first token, so the slope
//      (§58b: ms per prefill character) can be re-read with parameters
//      in it. Alternated run by run so thermal drift lands on all three.
//   2. THE ARGUMENTS (AC-276 b). Twenty sentences, three tools, greedy.
//      Each sentence has an expected outcome — a call with these
//      arguments, or NO call — and the row says what the model did:
//      right, no call, refused by the table in words, the wrong tool,
//      wrong arguments, or INVENTED (a number the person never said —
//      the one failure an app cannot live with). Totals at the end.
//
// The tools are THIS harness's stubs (D-027: the library ships no words).
// No system instruction by default (the 0.6B's only calling shape, 4w);
// `--system=` measures a candidate instruction — the 4B calls under one.

import Foundation
import MLXLMCommon
import MultiModalKit
import MultiModalKitMLX
import Synchronization

// MARK: - tool-contract: price the parameters, count the arguments

@MainActor
func runToolContract(_ arguments: [String]) async {
    guard MLXRuntime.isAvailable else {
        print("no Metal shader library reachable, so MLX cannot be touched at all.")
        print("fix it with:  Scripts/metallib.sh")
        exit(2)
    }
    guard let weights = askDefaultWeights(arguments),
          FileManager.default.fileExists(atPath: weights.path) else {
        print("no weights found. pass --model=/path/to/Qwen3-0.6B-4bit (or the phone's Qwen3-4B-4bit)")
        exit(2)
    }
    let runs = toolContractArgument("--runs=", in: arguments).flatMap(Int.init) ?? 3
    let instructions = toolContractArgument("--system=", in: arguments)
    let model = LocalMindModel(weights: weights)
    let stubs = ToolContractStubs()
    let clock = ContinuousClock()

    let bare = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: toolContractBudget)
    let spike = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: toolContractBudget,
                                  tools: ToolTable([stubs.session]))
    let verbs = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: toolContractBudget,
                                  tools: stubs.verbs)
    await askLoadAndWarm(model: model, mind: bare, weights: weights, clock: clock)
    for mind in [spike, verbs] {
        if let warm = try? await mind.openReply(to: ReplyContext(
            transcript: "hi", options: GenerationOptions(maxTokens: 1))) {
            for await _ in warm.updates { break }
            await warm.cancel()
        }
    }

    let repo = weights.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    print("model: \(repo) / \(weights.lastPathComponent)")
    print("runs: \(runs) per row · greedy (temperature 0) · budget \(toolContractBudget) tokens")
    print("instruction: " + (instructions.map { "\"\($0)\"" } ?? "NONE"))
    print("AC-276's numbers are PHONE numbers (§172c). This Mac shows the shape, not the claim.\n")

    await toolContractPrice(bare: bare, spike: spike, verbs: verbs, stubs: stubs, runs: runs, clock: clock)
    await toolContractArguments(verbs: verbs, stubs: stubs, clock: clock)
    exit(0)
}

// MARK: - the words

private let toolContractBudget = 120
private let toolContractPlainQuestion = "Name three capitals in Europe and one fact about each."

/// The twenty sentences and what a right answer is (AC-276 b).
private let toolContractSentences: [(say: String, expect: ToolContractExpectation)] = [
    // log_weight — a number the person said
    ("Log my weight as 83.5 kilos.", .call("log_weight", ["kg": .number(83.5)])),
    ("I weigh 84 kg this morning.", .call("log_weight", ["kg": .number(84)])),
    ("Record 82.7 kilograms.", .call("log_weight", ["kg": .number(82.7)])),
    ("My weight today is 85.", .call("log_weight", ["kg": .number(85)])),
    ("Put down eighty-three point two kilos.", .call("log_weight", ["kg": .number(83.2)])),
    ("Set my weight to 81.9 kg with the note: after the run.", .call("log_weight", ["kg": .number(81.9), "note": .contains("after the run")])),
    // add_extra — the food in the person's words
    ("I had two eggs and a coffee.", .call("add_extra", ["food": .contains("egg")])),
    ("Add a handful of almonds as a snack.", .call("add_extra", ["food": .contains("almond")])),
    ("I just ate a protein bar.", .call("add_extra", ["food": .contains("protein bar")])),
    ("Log an extra: half an avocado.", .call("add_extra", ["food": .contains("avocado")])),
    ("I also had a small salad after lunch.", .call("add_extra", ["food": .contains("salad")])),
    // tick_meal — the slot
    ("I finished lunch.", .call("tick_meal", ["slot": .string("first")])),
    ("Mark dinner as done.", .call("tick_meal", ["slot": .string("second")])),
    ("I ate my first meal.", .call("tick_meal", ["slot": .string("first")])),
    ("Dinner is eaten.", .call("tick_meal", ["slot": .string("second")])),
    ("Untick lunch, I did not eat it.", .call("tick_meal", ["slot": .string("first"), "done": .boolean(false)])),
    // no tool applies
    ("What is the weather like today?", .noCall),
    ("Tell me a short joke.", .noCall),
    // the trap: no number was said — a call with an invented one is the failure
    ("Log my weight.", .noNumber),
    ("Log my weight as heavy.", .noNumber)
]

// MARK: - the stubs

/// Emberleaf's first three verbs, as stubs that RECORD the call.
@MainActor
private final class ToolContractStubs: Sendable {
    private struct Record {
        var calls: [(name: String, arguments: ToolArguments)] = []
        var enteredAt: ContinuousClock.Instant?
    }
    private let record = Mutex(Record())
    private let clock = ContinuousClock()

    /// The spike's read, for the price table's middle column.
    var session: ReplyTool {
        ReplyTool(name: "session", description: "Read today's training session and the readiness verdict behind it.") { [self] arguments in
            note("session", arguments)
            return "Today is a 40 minute easy run, readiness 71."
        }
    }

    var verbs: ToolTable {
        ToolTable([
            ReplyTool(name: "log_weight",
                      description: "Record today's body weight.",
                      parameters: [
                        MultiModalKit.ToolParameter(name: "kg", description: "the weight in kilograms", kind: .number),
                        MultiModalKit.ToolParameter(name: "note", description: "an optional note", kind: .string, isRequired: false)
                      ]) { [self] arguments in
                note("log_weight", arguments)
                return "logged \(try arguments.number("kg")) kg"
            },
            ReplyTool(name: "add_extra",
                      description: "Record food eaten beside the planned meals, in the person's words.",
                      parameters: [
                        MultiModalKit.ToolParameter(name: "food", description: "what was eaten, as said", kind: .string)
                      ]) { [self] arguments in
                note("add_extra", arguments)
                return "added \(try arguments.string("food"))"
            },
            ReplyTool(name: "tick_meal",
                      description: "Mark a planned meal as eaten, or not. Lunch is the first meal, dinner the second.",
                      parameters: [
                        MultiModalKit.ToolParameter(name: "slot", description: "first or second", kind: .string),
                        MultiModalKit.ToolParameter(name: "done", description: "false to untick; true or absent to tick",
                                                    kind: .boolean, isRequired: false)
                      ]) { [self] arguments in
                note("tick_meal", arguments)
                let slot = try arguments.string("slot")
                let done = arguments.has("done") ? try arguments.boolean("done") : true
                return done ? "\(slot) meal marked eaten" : "\(slot) meal unticked"
            }
        ])
    }

    nonisolated private func note(_ name: String, _ arguments: ToolArguments) {
        let now = clock.now
        record.withLock { $0.calls.append((name, arguments)); if $0.enteredAt == nil { $0.enteredAt = now } }
    }
    func reset() { record.withLock { $0 = Record() } }
    var calls: [(name: String, arguments: ToolArguments)] { record.withLock { $0.calls } }
    var enteredAt: ContinuousClock.Instant? { record.withLock { $0.enteredAt } }
}

// MARK: - 1. the spec's price (AC-276 a)

@MainActor
private func toolContractPrice(bare: MLXReplyGenerator, spike: MLXReplyGenerator, verbs: MLXReplyGenerator,
                               stubs: ToolContractStubs, runs: Int, clock: ContinuousClock) async {
    print("## 1. the spec's price — first token on a question that needs no tool")
    // The spec's size, rendered the way the MLX mind renders it (the same
    // shape byte for byte — `ToolSpecTests` pins it), counted here because
    // the mind's own rendering is internal to it.
    let specChars = { (table: ToolTable) -> Int in
        table.tools.reduce(0) { total, tool in
            var properties: [String: Any] = [:]
            for parameter in tool.parameters {
                properties[parameter.name] = ["type": parameter.kind.rawValue, "description": parameter.description]
            }
            var schema: [String: Any] = ["type": "object", "properties": properties]
            let required = tool.parameters.filter(\.isRequired).map(\.name)
            if !required.isEmpty { schema["required"] = required }
            let spec: [String: Any] = ["type": "function",
                                       "function": ["name": tool.name, "description": tool.description,
                                                    "parameters": schema]]
            let data = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])) ?? Data()
            return total + data.count
        }
    }
    let rows: [(name: String, mind: MLXReplyGenerator, chars: Int)] = [
        ("no table", bare, 0),
        ("one tool, no parameters (4w)", spike, specChars(ToolTable([stubs.session]))),
        ("three tools with parameters", verbs, specChars(stubs.verbs))
    ]
    var firsts: [[Duration]] = rows.map { _ in [] }
    for _ in 0..<runs {
        for (index, row) in rows.enumerated() {
            let outcome = await toolContractAsk(mind: row.mind, question: toolContractPlainQuestion, stubs: stubs, clock: clock)
            firsts[index].append(outcome.firstToken)
        }
    }
    print("| table | spec chars | first token, median of \(runs) | delta vs no table |")
    print("|---|---|---|---|")
    let base = toolContractMedian(firsts[0])
    for (index, row) in rows.enumerated() {
        let median = toolContractMedian(firsts[index])
        let delta = toolContractMs(median) - toolContractMs(base)
        print("| \(row.name) | \(row.chars) | \(toolContractMs(median)) ms | \(delta >= 0 ? "+" : "")\(delta) ms |")
    }
    let deltaChars = rows[2].chars - rows[1].chars
    let deltaMs = toolContractMs(toolContractMedian(firsts[2])) - toolContractMs(toolContractMedian(firsts[1]))
    if deltaChars > 0 {
        print(String(format: "\nslope, parameters only: %.2f ms per spec character (%d chars, %+d ms)\n",
                     Double(deltaMs) / Double(deltaChars), deltaChars, deltaMs))
    }
}

// MARK: - 2. the arguments (AC-276 b)

private enum ToolContractExpectation {
    case call(String, [String: ToolContractMatch])
    case noCall
    /// No number was said: the right outcome is NO call, or a call the
    /// table refused in words — never a number.
    case noNumber
}

private enum ToolContractMatch {
    case number(Double)
    case string(String)
    case contains(String)
    case boolean(Bool)

    func matches(_ value: ToolValue?) -> Bool {
        guard let value else { return false }
        let arguments = ToolArguments(["v": value])
        switch self {
        case .number(let wanted): return (try? arguments.number("v")).map { abs($0 - wanted) < 0.01 } ?? false
        case .string(let wanted): return (try? arguments.string("v"))?.lowercased() == wanted.lowercased()
        case .contains(let wanted): return (try? arguments.string("v"))?.lowercased().contains(wanted.lowercased()) ?? false
        case .boolean(let wanted): return (try? arguments.boolean("v")) == wanted
        }
    }
}

@MainActor
private func toolContractArguments(verbs: MLXReplyGenerator, stubs: ToolContractStubs, clock: ContinuousClock) async {
    print("## 2. the arguments — twenty sentences, three tools, greedy")
    print("| # | said | expected | did | verdict | first token | total |")
    print("|---|---|---|---|---|---|---|")
    var tally: [String: Int] = [:]
    for (index, sentence) in toolContractSentences.enumerated() {
        let outcome = await toolContractAsk(mind: verbs, question: sentence.say, stubs: stubs, clock: clock)
        let did: String
        let verdict: String
        let refused = outcome.text.contains("cannot run") || outcome.text.contains("no tool named")
        switch (sentence.expect, outcome.calls.first) {
        case (.call(let name, let wanted), let call?):
            did = toolContractDescribe(call)
            if call.name != name {
                verdict = "WRONG TOOL"
            } else if wanted.allSatisfy({ $0.value.matches(call.arguments.values[$0.key]) }) {
                verdict = "right"
            } else {
                verdict = "wrong arguments"
            }
        case (.call, nil):
            did = refused ? "refused: \(outcome.text.prefix(60))" : "no call: \(outcome.text.prefix(60))"
            verdict = refused ? "refused" : "NO CALL"
        case (.noCall, let call?):
            did = toolContractDescribe(call)
            verdict = "UNWANTED CALL"
        case (.noCall, nil):
            did = "no call"
            verdict = "right"
        case (.noNumber, let call?):
            did = toolContractDescribe(call)
            verdict = "INVENTED"
        case (.noNumber, nil):
            did = refused ? "refused in words" : "no call"
            verdict = "right"
        }
        tally[verdict, default: 0] += 1
        let expected: String = switch sentence.expect {
        case .call(let name, let wanted): "\(name)(\(wanted.keys.sorted().joined(separator: ", ")))"
        case .noCall: "no call"
        case .noNumber: "no call / refused"
        }
        print("| \(index + 1) | \(sentence.say) | \(expected) | \(did) | \(verdict) "
              + "| \(toolContractMs(outcome.firstToken)) ms | \(toolContractMs(outcome.total)) ms |")
    }
    print("\ntotals: " + tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
          + " — of \(toolContractSentences.count)")
    print("INVENTED is the failure an app cannot live with; refused and NO CALL are the honest misses.")
}

private func toolContractDescribe(_ call: (name: String, arguments: ToolArguments)) -> String {
    let arguments = call.arguments.values.keys.sorted().map { key in
        "\(key): \(call.arguments.values[key].map { "\($0)" } ?? "")"
    }.joined(separator: ", ")
    return "\(call.name)(\(arguments))"
}

// MARK: - one reply, drained by hand

private struct ToolContractOutcome {
    var text = ""
    var firstToken: Duration = .zero
    var total: Duration = .zero
    var calls: [(name: String, arguments: ToolArguments)] = []
}

@MainActor
private func toolContractAsk(mind: MLXReplyGenerator, question: String,
                             stubs: ToolContractStubs, clock: ContinuousClock) async -> ToolContractOutcome {
    stubs.reset()
    var outcome = ToolContractOutcome()
    let start = clock.now
    var sawFirst = false
    do {
        let run = try await mind.openReply(to: ReplyContext(
            transcript: question, options: GenerationOptions(temperature: 0)))
        for await update in run.updates {
            switch update {
            case .token(let token):
                if !sawFirst { sawFirst = true; outcome.firstToken = start.duration(to: clock.now) }
                outcome.text += token
            case .finished, .failed:
                break
            }
        }
    } catch {
        outcome.text = "failed: \(error)"
    }
    outcome.total = start.duration(to: clock.now)
    outcome.calls = stubs.calls
    return outcome
}

// MARK: - small helpers

private func toolContractArgument(_ prefix: String, in arguments: [String]) -> String? {
    arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

private func toolContractMs(_ duration: Duration) -> Int {
    Int((Double(duration.components.seconds) * 1000
         + Double(duration.components.attoseconds) / 1e15).rounded())
}

private func toolContractMedian(_ durations: [Duration]) -> Duration {
    let sorted = durations.sorted()
    guard !sorted.isEmpty else { return .zero }
    return sorted[sorted.count / 2]
}
