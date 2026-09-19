// The `tool-contract` instrument (4z, AC-281 — the Mac half). The harness
// before the phone (the house rule, §172c): the phone's rows are Ryad's
// gate; nothing printed here claims them. The 4B — the phone's own model
// — is in this Mac's cache, so `--model=` the 4B is the closest a Mac
// gets to the phone's answer.
//
// FIVE MEASUREMENTS, in the order §69 reads them:
//
//   1. THE SPEC'S PRICE. A question that needs no tool, against no table,
//      4w's one-tool table (no parameters), and three tools WITH
//      parameters. The first token and the spec's characters, so the
//      cost per parameter character can be read — alternated run by run
//      so thermal drift lands on all three.
//   2. THE ARGUMENTS. Twenty sentences, three tools, greedy: right, no
//      call, refused in words, the wrong tool, wrong arguments, or
//      INVENTED (a number the person never said).
//   3. INVENTED with `kg` REQUIRED and with it OPTIONAL — nobody had
//      measured optional: a required parameter is a demand the model
//      meets from nothing (F-11 B's first caution).
//   4. THE BAND, hidden and shown (F-11 B's two switches): does showing
//      20…400 to the model change what it writes when no number was said?
//   5. ONE TOOL ROUND's price (F-13 h): the call's own trip — question to
//      the call, the stub itself, the call to the first word after it.
//
// The Apple mind runs the same twenty sentences when `--apple` is passed
// and the on-device model is ready; otherwise the instrument says NOT
// RUN, in those words (D-054).
//
// The tools are THIS harness's stubs (D-027: the library ships no words).
// No system instruction by default (the 0.6B's only calling shape, 4w);
// `--system=` measures a candidate instruction — the 4B calls under one.

import Foundation
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
    guard let bare = try? MLXReplyGenerator(model: model, instructions: instructions,
                                            maxTokens: toolContractBudget) else {
        print("the MLX mind refused an EMPTY table — a library bug."); exit(2)
    }
    await askLoadAndWarm(model: model, mind: bare, weights: weights, clock: clock)

    let repo = weights.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    print("model: \(repo) / \(weights.lastPathComponent)")
    print("runs: \(runs) per price row · greedy (temperature 0) · budget \(toolContractBudget) tokens")
    print("instruction: " + (instructions.map { "\"\($0)\"" } ?? "NONE"))
    print("AC-281's phone rows are Ryad's gate (§172c). This Mac shows the shape, not the claim.\n")

    await toolContractPrice(bare: bare, stubs: stubs, runs: runs, clock: clock)
    let verbs = ToolContractRig(mind: bare, table: stubs.verbs(kgRequired: true, showsRange: false))
    let round = await toolContractArguments(rig: verbs, stubs: stubs, clock: clock,
                                            title: "## 2. the arguments — twenty sentences, three tools, greedy")
    await toolContractTraps(mind: bare, stubs: stubs, clock: clock)
    toolContractRound(round)
    if arguments.contains("--apple") { await toolContractApple(stubs: stubs, clock: clock) }
    exit(0)
}

// MARK: - the words

private let toolContractBudget = 120
private let toolContractPlainQuestion = "Name three capitals in Europe and one fact about each."

/// A sentence and what a right answer is.
private struct ToolContractSentence {
    let say: String
    let expect: ToolContractExpectation
}

/// The twenty sentences (the arguments' measurement).
private let toolContractSentences: [ToolContractSentence] = [
    // log_weight — a number the person said
    .init(say: "Log my weight as 83.5 kilos.", expect: .call("log_weight", ["kg": .number(83.5)])),
    .init(say: "I weigh 84 kg this morning.", expect: .call("log_weight", ["kg": .number(84)])),
    .init(say: "Record 82.7 kilograms.", expect: .call("log_weight", ["kg": .number(82.7)])),
    .init(say: "My weight today is 85.", expect: .call("log_weight", ["kg": .number(85)])),
    .init(say: "Put down eighty-three point two kilos.", expect: .call("log_weight", ["kg": .number(83.2)])),
    .init(say: "Set my weight to 81.9 kg with the note: after the run.",
          expect: .call("log_weight", ["kg": .number(81.9), "note": .contains("after the run")])),
    // add_extra — the food in the person's words
    .init(say: "I had two eggs and a coffee.", expect: .call("add_extra", ["food": .contains("egg")])),
    .init(say: "Add a handful of almonds as a snack.", expect: .call("add_extra", ["food": .contains("almond")])),
    .init(say: "I just ate a protein bar.", expect: .call("add_extra", ["food": .contains("protein bar")])),
    .init(say: "Log an extra: half an avocado.", expect: .call("add_extra", ["food": .contains("avocado")])),
    .init(say: "I also had a small salad after lunch.", expect: .call("add_extra", ["food": .contains("salad")])),
    // tick_meal — the slot
    .init(say: "I finished lunch.", expect: .call("tick_meal", ["slot": .string("first")])),
    .init(say: "Mark dinner as done.", expect: .call("tick_meal", ["slot": .string("second")])),
    .init(say: "I ate my first meal.", expect: .call("tick_meal", ["slot": .string("first")])),
    .init(say: "Dinner is eaten.", expect: .call("tick_meal", ["slot": .string("second")])),
    .init(say: "Untick lunch, I did not eat it.",
          expect: .call("tick_meal", ["slot": .string("first"), "done": .boolean(false)])),
    // no tool applies
    .init(say: "What is the weather like today?", expect: .noCall),
    .init(say: "Tell me a short joke.", expect: .noCall),
    // the trap: no number was said — a call with an invented one is the failure
    .init(say: "Log my weight.", expect: .noNumber),
    .init(say: "Log my weight as heavy.", expect: .noNumber)
]

/// The two trap sentences, measured again under the other switches.
private let toolContractTrapSentences = Array(toolContractSentences.suffix(2))

// MARK: - the stubs

/// A call the stubs saw.
private struct ToolContractCall {
    let name: String
    let arguments: ToolArguments
}

/// Three verbs as stubs that RECORD the call and when it entered.
private final class ToolContractStubs: Sendable {
    private struct Record {
        var calls: [ToolContractCall] = []
        var enteredAt: ContinuousClock.Instant?
    }
    private let record = Mutex(Record())
    private let clock = ContinuousClock()

    /// 4w's one read, for the price table's middle row.
    var session: ReplyTool {
        ReplyTool(name: "session",
                  description: "Read today's training session and the readiness verdict behind it.",
                  parameters: [], requiresConfirmation: false) { [self] arguments in
            note("session", arguments)
            return "Today is a 40 minute easy run, readiness 71."
        }
    }

    /// The three verbs, with the two switches §69 measures.
    func verbs(kgRequired: Bool, showsRange: Bool) -> ToolTable {
        let weight = ReplyTool(name: "log_weight", description: "Record today's body weight.",
                               parameters: [
                                ToolParameter(name: "kg", description: "the weight in kilograms",
                                              kind: .number, isRequired: kgRequired,
                                              range: 20...400, showsRange: showsRange),
                                ToolParameter(name: "note", description: "an optional note",
                                              kind: .string, isRequired: false)
                               ], requiresConfirmation: false) { [self] arguments in
            note("log_weight", arguments)
            return "logged \(try arguments.number("kg")) kg"
        }
        let extra = ReplyTool(name: "add_extra",
                              description: "Record food eaten beside the planned meals, in the person's words.",
                              parameters: [ToolParameter(name: "food", description: "what was eaten, as said",
                                                         kind: .string, isRequired: true)],
                              requiresConfirmation: false) { [self] arguments in
            note("add_extra", arguments)
            return "added \(try arguments.string("food"))"
        }
        let meal = ReplyTool(name: "tick_meal",
                             description: "Mark a planned meal as eaten, or not. Lunch is the first meal, "
                                + "dinner the second.",
                             parameters: [
                                ToolParameter(name: "slot", description: "first or second",
                                              kind: .string, isRequired: true),
                                ToolParameter(name: "done", description: "false to untick; true or absent to tick",
                                              kind: .boolean, isRequired: false)
                             ], requiresConfirmation: false) { [self] arguments in
            note("tick_meal", arguments)
            let slot = try arguments.string("slot")
            let done = arguments.has("done") ? try arguments.boolean("done") : true
            return done ? "\(slot) meal marked eaten" : "\(slot) meal unticked"
        }
        return ToolTable([weight, extra, meal])
    }

    private func note(_ name: String, _ arguments: ToolArguments) {
        let now = clock.now
        record.withLock {
            $0.calls.append(ToolContractCall(name: name, arguments: arguments))
            if $0.enteredAt == nil { $0.enteredAt = now }
        }
    }
    func reset() { record.withLock { $0 = Record() } }
    var calls: [ToolContractCall] { record.withLock { $0.calls } }
    var enteredAt: ContinuousClock.Instant? { record.withLock { $0.enteredAt } }
}

/// A mind and the table its calls carry (F-2 = A: the table rides on the
/// call, so one mind serves every row).
private struct ToolContractRig {
    let mind: any ReplyGenerating
    let table: ToolTable
}

// MARK: - 1. the spec's price

/// The spec's characters, rendered the way the MLX mind renders them
/// (sorted keys — the same bytes `ToolSpecTests` pins).
private func toolContractSpecChars(_ table: ToolTable) -> Int {
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

@MainActor
private func toolContractPrice(bare: MLXReplyGenerator, stubs: ToolContractStubs,
                               runs: Int, clock: ContinuousClock) async {
    print("## 1. the spec's price — first token on a question that needs no tool")
    let tables: [(name: String, table: ToolTable)] = [
        ("no table", .empty),
        ("one tool, no parameters (4w)", ToolTable([stubs.session])),
        ("three tools with parameters", stubs.verbs(kgRequired: true, showsRange: false))
    ]
    var firsts: [[Duration]] = tables.map { _ in [] }
    for _ in 0..<runs {
        for (index, row) in tables.enumerated() {
            let rig = ToolContractRig(mind: bare, table: row.table)
            let outcome = await toolContractAsk(rig: rig, question: toolContractPlainQuestion,
                                                stubs: stubs, clock: clock)
            firsts[index].append(outcome.firstToken)
        }
    }
    print("| table | spec chars | first token, median of \(runs) | delta vs no table |")
    print("|---|---|---|---|")
    let base = toolContractMs(toolContractMedian(firsts[0]))
    for (index, row) in tables.enumerated() {
        let median = toolContractMs(toolContractMedian(firsts[index]))
        let delta = median - base
        let sign = delta >= 0 ? "+" : ""
        print("| \(row.name) | \(toolContractSpecChars(row.table)) | \(median) ms | \(sign)\(delta) ms |")
    }
    let chars = toolContractSpecChars(tables[2].table) - toolContractSpecChars(tables[1].table)
    let ms = toolContractMs(toolContractMedian(firsts[2])) - toolContractMs(toolContractMedian(firsts[1]))
    if chars > 0 {
        print(String(format: "\nslope, parameters only: %.2f ms per spec character (%d chars, %+d ms)",
                     Double(ms) / Double(chars), chars, ms))
    }
    print("spec chars = the tool JSON with sorted keys; §67's +559 was the whole rendered PROMPT's growth.\n")
}

// MARK: - 2. the arguments

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
        case .contains(let wanted):
            return (try? arguments.string("v"))?.lowercased().contains(wanted.lowercased()) ?? false
        case .boolean(let wanted): return (try? arguments.boolean("v")) == wanted
        }
    }
}

/// What a sentence's row says, from what the model did.
private func toolContractVerdict(_ sentence: ToolContractSentence,
                                 _ outcome: ToolContractOutcome) -> (did: String, verdict: String) {
    let refused = outcome.text.contains("cannot run") || outcome.text.contains("no tool named")
    switch (sentence.expect, outcome.calls.first) {
    case (.call(let name, let wanted), let call?):
        let did = toolContractDescribe(call)
        if call.name != name { return (did, "WRONG TOOL") }
        let right = wanted.allSatisfy { $0.value.matches(call.arguments.values[$0.key]) }
        return (did, right ? "right" : "wrong arguments")
    case (.call, nil):
        return (refused ? "refused: \(outcome.text.prefix(60))" : "no call: \(outcome.text.prefix(60))",
                refused ? "refused" : "NO CALL")
    case (.noCall, let call?): return (toolContractDescribe(call), "UNWANTED CALL")
    case (.noCall, nil): return ("no call", "right")
    case (.noNumber, let call?):
        // A call that carries NO number is the honest outcome under an
        // optional `kg`; only a number the person never said is INVENTED.
        let invented = call.arguments.has("kg")
        return (toolContractDescribe(call), invented ? "INVENTED" : "right (call, no number)")
    case (.noNumber, nil): return (refused ? "refused in words" : "no call", "right")
    }
}

/// The twenty sentences through one rig; returns the tool rounds seen,
/// for the round's price.
@MainActor
private func toolContractArguments(rig: ToolContractRig, stubs: ToolContractStubs,
                                   clock: ContinuousClock, title: String) async -> [ToolContractRound] {
    print(title)
    print("| # | said | expected | did | verdict | first token | total |")
    print("|---|---|---|---|---|---|---|")
    var tally: [String: Int] = [:]
    var rounds: [ToolContractRound] = []
    for (index, sentence) in toolContractSentences.enumerated() {
        let outcome = await toolContractAsk(rig: rig, question: sentence.say, stubs: stubs, clock: clock)
        let (did, verdict) = toolContractVerdict(sentence, outcome)
        tally[verdict, default: 0] += 1
        if let round = outcome.round { rounds.append(round) }
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
    print("INVENTED is the failure an app cannot live with; refused and NO CALL are the honest misses.\n")
    return rounds
}

private func toolContractDescribe(_ call: ToolContractCall) -> String {
    let arguments = call.arguments.values.keys.sorted().map { key in
        "\(key): \(call.arguments.values[key].map { "\($0)" } ?? "")"
    }.joined(separator: ", ")
    return "\(call.name)(\(arguments))"
}

// MARK: - 3 and 4. the traps, under the other switches

/// One setting of F-11 B's two switches, named for the row.
private struct ToolContractSwitches {
    let name: String
    let required: Bool
    let shown: Bool
}

/// The two trap sentences with `kg` optional, and with the band shown.
@MainActor
private func toolContractTraps(mind: MLXReplyGenerator, stubs: ToolContractStubs, clock: ContinuousClock) async {
    print("## 3 and 4. the trap sentences under the other switches (F-11 B)")
    print("| switches | said | did | verdict |")
    print("|---|---|---|---|")
    let switches: [ToolContractSwitches] = [
        .init(name: "kg required · band hidden (the twenty above)", required: true, shown: false),
        .init(name: "kg OPTIONAL · band hidden", required: false, shown: false),
        .init(name: "kg required · band SHOWN 20…400", required: true, shown: true),
        .init(name: "kg OPTIONAL · band SHOWN 20…400", required: false, shown: true)
    ]
    for setting in switches {
        let rig = ToolContractRig(mind: mind, table: stubs.verbs(kgRequired: setting.required,
                                                                showsRange: setting.shown))
        for sentence in toolContractTrapSentences {
            let outcome = await toolContractAsk(rig: rig, question: sentence.say, stubs: stubs, clock: clock)
            let (did, verdict) = toolContractVerdict(sentence, outcome)
            print("| \(setting.name) | \(sentence.say) | \(did) | \(verdict) |")
        }
    }
    print("\nrequired = a demand the model meets from nothing; a band SHOWN under constrained decoding")
    print("turns a catchable 0 into an uncatchable 75 — the two cautions of F-11 B, measured.\n")
}

// MARK: - 5. one tool round's price

/// One trip model → tool → model, as the clocks saw it.
private struct ToolContractRound {
    let questionToCall: Duration
    let afterCall: Duration
}

private func toolContractRound(_ rounds: [ToolContractRound]) {
    print("## 5. one tool round's price (F-13 h) — the calls above, medians")
    guard !rounds.isEmpty else { print("no tool was called, so no round was priced.\n"); return }
    let toCall = toolContractMs(toolContractMedian(rounds.map(\.questionToCall)))
    let after = toolContractMs(toolContractMedian(rounds.map(\.afterCall)))
    print("rounds priced: \(rounds.count) · median question→call \(toCall) ms · "
          + "call→first word after the answer \(after) ms · one round ≈ \(toCall + after) ms\n")
}

// MARK: - the Apple mind, when it is ready

@MainActor
private func toolContractApple(stubs: ToolContractStubs, clock: ContinuousClock) async {
    print("## the Apple mind — the same twenty sentences")
    guard #available(macOS 26.0, *) else { print("NOT RUN: needs macOS 26.\n"); return }
    if let verdict = AppleMind.readiness() { print("NOT RUN: \(verdict)\n"); return }
    guard let apple = try? AppleReplyGenerator() else { print("NOT RUN: the init refused an empty table.\n"); return }
    let rig = ToolContractRig(mind: apple, table: stubs.verbs(kgRequired: true, showsRange: false))
    _ = await toolContractArguments(rig: rig, stubs: stubs, clock: clock,
                                    title: "twenty sentences on the Apple mind, greedy")
}

// MARK: - one reply, drained by hand

private struct ToolContractOutcome {
    var text = ""
    var firstToken: Duration = .zero
    var total: Duration = .zero
    var calls: [ToolContractCall] = []
    var round: ToolContractRound?
}

@MainActor
private func toolContractAsk(rig: ToolContractRig, question: String,
                             stubs: ToolContractStubs, clock: ContinuousClock) async -> ToolContractOutcome {
    stubs.reset()
    var outcome = ToolContractOutcome()
    let start = clock.now
    var firstAfterCall: ContinuousClock.Instant?
    do {
        let run = try await rig.mind.openReply(to: ReplyContext(
            transcript: question, options: GenerationOptions(temperature: 0, tools: rig.table)))
        for await update in run.updates {
            guard case .token(let token) = update else { continue }
            let now = clock.now
            if outcome.text.isEmpty { outcome.firstToken = start.duration(to: now) }
            if firstAfterCall == nil, stubs.enteredAt != nil { firstAfterCall = now }
            outcome.text += token
        }
    } catch {
        outcome.text = "failed: \(error)"
    }
    outcome.total = start.duration(to: clock.now)
    outcome.calls = stubs.calls
    if let entered = stubs.enteredAt, let after = firstAfterCall {
        outcome.round = ToolContractRound(questionToCall: start.duration(to: entered),
                                          afterCall: entered.duration(to: after))
    }
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
