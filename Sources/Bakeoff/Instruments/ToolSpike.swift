// The `tool-spike` instrument (4w, AC-227 / AC-228 — the Mac half): what a
// tool table costs a reply that never uses it, and what a tool call costs
// a reply that does, on this Mac. The harness before the phone (the house
// rule, §172c): AC-227's "< 10 ms" and AC-228's prices are PHONE numbers
// and Ryad's gate; nothing printed here claims them. What this prints is
// the shape of the cost — where it is, and how big it is relative to the
// reply — so the phone sitting knows what it is looking for.
//
// THREE MEASUREMENTS, THREE QUESTIONS:
//
//   1. THE PLAIN PATH (AC-227). A question that needs no tool, asked
//      against a mind with no table and against one with a one-tool table
//      whose tool is never called. The same weights, greedy, alternated
//      run by run so thermal drift lands on both. The delta is the price
//      of the spec in the prompt (prefill) plus the call sieve on the
//      loop — the whole of what an idle tool costs.
//   2. THE TOOL PATH (AC-228). The question that WORKS on the 0.6B
//      ("Use the session tool to…", the spike's first finding, AC-222's
//      as-built note): question→call, the stub's own duration, call→first
//      word after the answer, total. The same question against the
//      no-table mind is the control: what a mind with no tool says when
//      asked to use one.
//   3. THE FINDING, REPRODUCED. "What is today's session?" — the tool not
//      named — against the one-tool mind. On the 0.6B the model does not
//      call. That sentence lived in a test's comment; now an instrument
//      prints it — and asked of the 4B (the phone's model) the answer
//      flipped: it calls the unnamed tool 5 of 5, with or without an
//      instruction (docs/evidence/4w). The finding is the 0.6B's, not the
//      contract's, which is exactly why an instrument and not a comment.
//
// The stub is THIS harness's (§168a: the demo owns its own). The library
// ships no words for it (D-027). No system instruction by default: the
// spike found that ANY instruction beside the naming question stops the
// 0.6B from calling, so the default is the shape that holds and
// `--system=` is how a candidate instruction gets measured, not assumed.
import Foundation
import MLXLMCommon
import MultiModalKit
import MultiModalKitMLX
import Synchronization

// MARK: - tool-spike: price the idle table, the call, and the finding

@MainActor
func runToolSpike(_ arguments: [String]) async {
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
    let runs = toolSpikeArgument("--runs=", in: arguments).flatMap(Int.init) ?? 5
    let instructions = toolSpikeArgument("--system=", in: arguments)
    let model = LocalMindModel(weights: weights)
    let stub = ToolSpikeStub()
    // The SAME budget on both minds, or the delta measures the budget.
    let bare = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: toolSpikeBudget)
    let tooled = MLXReplyGenerator(model: model, instructions: instructions, maxTokens: toolSpikeBudget,
                                   tools: ToolTable([stub.tool]))
    let clock = ContinuousClock()
    await askLoadAndWarm(model: model, mind: bare, weights: weights, clock: clock)
    // The tooled mind's first breath too, so run 1 of the tool path is
    // the tool path's number and not the sieve's first construction.
    if let warm = try? await tooled.openReply(to: ReplyContext(
        transcript: "hi", options: GenerationOptions(maxTokens: 1))) {
        for await _ in warm.updates { break }
        await warm.cancel()
    }

    let repo = weights.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    print("model: \(repo) / \(weights.lastPathComponent)")
    print("runs: \(runs) per row · greedy (temperature 0) · budget \(toolSpikeBudget) tokens")
    print("instruction: " + (instructions.map { "\"\($0)\"" }
                           ?? "NONE — the only shape the 0.6B calls under (AC-222's note)"))
    print("the stub says: \"\(toolSpikeSession)\"")
    print("AC-227's < 10 ms and AC-228's prices are PHONE numbers (§172c). "
          + "This Mac shows the shape, not the claim.\n")

    await toolSpikePlainPath(bare: bare, tooled: tooled, stub: stub, runs: runs, clock: clock)
    await toolSpikeToolPath(bare: bare, tooled: tooled, stub: stub, runs: runs, clock: clock)
    await toolSpikeFinding(tooled: tooled, stub: stub, runs: runs, clock: clock)
    await toolSpikePrefill(model: model, instructions: instructions)
    exit(0)
}

// MARK: - the words

/// The stub's answer — the harness's own, not the demo's (§168a). The
/// numbers are the distinctive words a reply must carry: no question
/// about a training session produces "40" and "71" by accident.
private let toolSpikeSession = "Today is a 40 minute easy run, readiness 71."
/// AC-227's question: needs no tool, so the table is pure overhead.
private let toolSpikePlainQuestion = "Name three capitals in Europe and one fact about each."
/// AC-228's question: the shape that WORKS on the 0.6B — the tool named
/// by the person (the spike's first finding).
private let toolSpikeNamingQuestion = "Use the session tool to find out what today's session is."
/// The finding's question: the tool NOT named. The 0.6B answers without it.
private let toolSpikeUnnamedQuestion = "What is today's session?"
/// 160, the `ask` and `determinism` budget — a spoken-reply size, so the
/// plain path's total is a reply Aura's check-in would pay for.
private let toolSpikeBudget = 160
/// The tool tables' header: the tool columns, then the shared ones.
private let toolSpikeToolHeader = "| mind | run | called | question→call | the stub itself "
    + "| call→first word after | first token | total | stop | chars | pieces | decode ms/piece |\n"
    + "|---|---|---|---|---|---|---|---|---|---|---|---|"

// MARK: - 1. the plain path (AC-227, Mac half)

@MainActor
private func toolSpikePlainPath(bare: MLXReplyGenerator, tooled: MLXReplyGenerator,
                                stub: ToolSpikeStub, runs: Int, clock: ContinuousClock) async {
    print("## 1. The plain path — no tool needed, with and without a table (AC-227's Mac half)\n")
    print("question: \(toolSpikePlainQuestion)\n")
    print("| table | run | first token | total | stop | chars | pieces | decode ms/piece | tool called |")
    print("|---|---|---|---|---|---|---|---|---|")
    var bareRuns: [ToolSpikeOutcome] = []
    var tooledRuns: [ToolSpikeOutcome] = []
    // ALTERNATED, not batched: a Mac warms up and throttles over N runs,
    // and a delta between two batches would carry the drift.
    for run in 1...runs {
        let plain = await toolSpikeAsk(mind: bare, question: toolSpikePlainQuestion, stub: stub, clock: clock)
        print("| .empty | \(run) | \(plain.row) | \(plain.calls == 0 ? "no" : "yes") |")
        bareRuns.append(plain)
        let withTable = await toolSpikeAsk(mind: tooled, question: toolSpikePlainQuestion,
                                           stub: stub, clock: clock)
        print("| one tool, never called | \(run) | \(withTable.row) | \(withTable.calls == 0 ? "no" : "yes") |")
        tooledRuns.append(withTable)
    }
    // THE FELT PAUSE IS THE FIRST TOKEN (AC-227's "felt pause"): the
    // spec is prefill, and prefill is paid before the first word. The
    // total is printed but not the verdict — the two prompts differ, so
    // greedy decoding walks different paths and the replies differ in
    // length; the per-piece decode rate is the loop's fair comparison.
    let bareFirst = toolSpikeMs(toolSpikeMedian(bareRuns.map(\.firstToken)))
    let tooledFirst = toolSpikeMs(toolSpikeMedian(tooledRuns.map(\.firstToken)))
    let bareRate = toolSpikeMedianDouble(bareRuns.map(\.decodeMsPerPiece))
    let tooledRate = toolSpikeMedianDouble(tooledRuns.map(\.decodeMsPerPiece))
    print("\nmedian first token: .empty \(bareFirst) ms · one tool \(tooledFirst) ms · "
          + "**the table costs \(toolSpikeSigned(tooledFirst - bareFirst)) ms on the felt pause** "
          + "(this Mac; the phone decides AC-227)")
    print(String(format: "median decode: .empty %.2f ms/piece · one tool %.2f ms/piece · "
                 + "the sieve costs %+.2f ms/piece", bareRate, tooledRate, tooledRate - bareRate))
    print("median total: .empty \(toolSpikeMs(toolSpikeMedian(bareRuns.map(\.total)))) ms · "
          + "one tool \(toolSpikeMs(toolSpikeMedian(tooledRuns.map(\.total)))) ms "
          + "(not comparable: the replies differ, see below)")
    print("the tool was called \(tooledRuns.map(\.calls).reduce(0, +)) times across the one-tool runs (must be 0)")
    let sameBytes = bareRuns.first?.text == tooledRuns.first?.text
    print("same bytes with and without the table: "
          + (sameBytes ? "yes" : "NO — the spec is in the prompt, so greedy decoding takes another path"))
    print("\n  .empty said: \(bareRuns.first?.text.prefix(200) ?? "")")
    print("  one tool said: \(tooledRuns.first?.text.prefix(200) ?? "")\n")
}

// MARK: - 2. the tool path (AC-228, Mac half)

@MainActor
private func toolSpikeToolPath(bare: MLXReplyGenerator, tooled: MLXReplyGenerator,
                               stub: ToolSpikeStub, runs: Int, clock: ContinuousClock) async {
    print("## 2. The tool path — the tool named (AC-228's Mac half)\n")
    print("question: \(toolSpikeNamingQuestion)\n")
    print(toolSpikeToolHeader)
    var tooledRuns: [ToolSpikeOutcome] = []
    var bareRuns: [ToolSpikeOutcome] = []
    for run in 1...runs {
        let called = await toolSpikeAsk(mind: tooled, question: toolSpikeNamingQuestion,
                                        stub: stub, clock: clock)
        print("| one tool | \(run) | \(called.toolRow) | \(called.row) |")
        tooledRuns.append(called)
        // THE CONTROL: the same words to a mind that has no tool. What
        // it says is the honest baseline for "the answer went back".
        let control = await toolSpikeAsk(mind: bare, question: toolSpikeNamingQuestion,
                                         stub: stub, clock: clock)
        print("| .empty (control) | \(run) | \(control.toolRow) | \(control.row) |")
        bareRuns.append(control)
    }
    let rounds = tooledRuns.filter { $0.calls > 0 }
    print("\ncalled in \(rounds.count) of \(runs) runs; "
          + "carries the stub's numbers (40, 71) in \(tooledRuns.filter(\.carriesAnswer).count) of \(runs)")
    if !rounds.isEmpty {
        let toCall = toolSpikeMs(toolSpikeMedian(rounds.compactMap(\.questionToCall)))
        let after = toolSpikeMs(toolSpikeMedian(rounds.compactMap(\.callToFirstWordAfter)))
        print("median question→call \(toCall) ms · call→first word after the answer \(after) ms · "
              + "total \(toolSpikeMs(toolSpikeMedian(rounds.map(\.total)))) ms")
    }
    print("the control (no tool) median total \(toolSpikeMs(toolSpikeMedian(bareRuns.map(\.total)))) ms; "
          + "carries the numbers in \(bareRuns.filter(\.carriesAnswer).count) of \(runs) "
          + "(must be 0 — it has no tool)")
    print("\n  one tool said: \(tooledRuns.first?.text.prefix(300) ?? "")")
    print("  .empty said: \(bareRuns.first?.text.prefix(300) ?? "")\n")
}

// MARK: - 3. the finding, reproduced (AC-222's as-built note)

@MainActor
private func toolSpikeFinding(tooled: MLXReplyGenerator, stub: ToolSpikeStub,
                              runs: Int, clock: ContinuousClock) async {
    print("## 3. The finding — the tool NOT named, one-tool mind (AC-222's as-built note)\n")
    print("question: \(toolSpikeUnnamedQuestion)\n")
    print(toolSpikeToolHeader)
    var outcomes: [ToolSpikeOutcome] = []
    for run in 1...runs {
        let outcome = await toolSpikeAsk(mind: tooled, question: toolSpikeUnnamedQuestion,
                                         stub: stub, clock: clock)
        print("| one tool | \(run) | \(outcome.toolRow) | \(outcome.row) |")
        outcomes.append(outcome)
    }
    let called = outcomes.filter { $0.calls > 0 }.count
    print("\ncalled in \(called) of \(runs) runs — "
          + (called == 0
             ? "the spike's finding holds on these weights: the tool is called only when the person names it."
             : "these weights DO call an unnamed tool; the 0.6B's finding does not transfer to them."))
    print("\n  said: \(outcomes.first?.text.prefix(300) ?? "")\n")
}

// MARK: - 4. what the spec costs to prefill (AC-228's "spec prefill")

/// The prompt with the spec rendered against the same prompt without it:
/// the vendor's own token count and the decoded text's character count,
/// so §58b's per-character slope prices it. Copied from
/// `MLXToolLiveTests` — the same `prepare`, the same roles.
///
/// THE SPEC IS BUILT HERE BY HAND, mirroring `ReplyTool.toolSpec` (an
/// internal member of the MLX module this executable cannot reach). A
/// copy is a risk the file owns: if the library's spec grows a field,
/// this count is stale until the copy is. The honest fix is a public
/// way to ask the mind what its prompt weighs; until then the plain path
/// above (which DOES run the library's own spec) is the corroboration.
@MainActor
private func toolSpikePrefill(model: LocalMindModel, instructions: String?) async {
    print("## 4. What the spec costs to prefill — tokens and characters, with and without\n")
    guard let container = try? await model.ensureModelLoaded() else {
        print("could not reach the loaded model for the prefill count."); return
    }
    let spec: ToolSpec = [
        "type": "function",
        "function": [
            "name": "session",
            "description": toolSpikeDescription,
            "parameters": ["type": "object",
                           "properties": [String: any Sendable]()] as [String: any Sendable]
        ] as [String: any Sendable]
    ]
    print("| question | without the spec | with the spec | the spec adds |")
    print("|---|---|---|---|")
    for question in [toolSpikePlainQuestion, toolSpikeNamingQuestion, toolSpikeUnnamedQuestion] {
        let size = { (tools: [ToolSpec]?) async throws -> (tokens: Int, chars: Int) in
            try await container.perform { (model: ModelContext) in
                var chat: [Chat.Message] = []
                if let instructions { chat.append(.system(instructions)) }
                chat.append(.user(question))
                let input = try await model.processor.prepare(input: UserInput(
                    chat: chat, tools: tools, additionalContext: ["enable_thinking": false]))
                let ids = input.text.tokens.asArray(Int.self)
                return (ids.count, model.tokenizer.decode(tokenIds: ids).count)
            }
        }
        guard let without = try? await size(nil), let with = try? await size([spec]) else {
            print("| \(question) | failed to prepare | | |"); continue
        }
        print("| \(question) | \(without.tokens) tokens / \(without.chars) chars "
              + "| \(with.tokens) tokens / \(with.chars) chars "
              + "| **+\(with.tokens - without.tokens) tokens / +\(with.chars - without.chars) chars** |")
    }
    print("\nnot measured here: the phone's prefill time for those tokens (AC-228), the felt pause on the")
    print("phone (AC-227), and the audio-thread allocation probe (graph-probe is its own instrument).")
    print("Those are the phone sitting's (§172c).")
}

// MARK: - the stub, and what one run recorded

private let toolSpikeDescription = "Read today's training session and readiness."

/// The harness's session read: answers instantly from a fixed sentence,
/// and records WHEN it was entered and how long it took, so the run's
/// clock can split "question→call" from "call→first word after".
private final class ToolSpikeStub: Sendable {
    private struct Record {
        var calls = 0
        var enteredAt: ContinuousClock.Instant?
        var duration: Duration?
    }
    private let record = Mutex(Record())
    private let clock = ContinuousClock()

    var tool: ReplyTool {
        // `self`, not `record`: a `Mutex` cannot be copied into a capture
        // list, and this class is `Sendable` so the closure may hold it.
        ReplyTool(name: "session", description: toolSpikeDescription) { [self] _ in
            let entered = clock.now
            record.withLock { $0.calls += 1; $0.enteredAt = entered }
            let answer = toolSpikeSession
            record.withLock { $0.duration = entered.duration(to: clock.now) }
            return answer
        }
    }

    func reset() { record.withLock { $0 = Record() } }
    var calls: Int { record.withLock { $0.calls } }
    var enteredAt: ContinuousClock.Instant? { record.withLock { $0.enteredAt } }
    var duration: Duration? { record.withLock { $0.duration } }
}

private struct ToolSpikeOutcome {
    var text = ""
    /// `.token` updates seen — the seam's pieces, not the vendor's token
    /// count (the sieve may merge), but the same unit on both minds.
    var pieces = 0
    var stop: StopReason?
    var failure: String?
    var firstToken: Duration = .zero
    var total: Duration = .zero
    var calls = 0
    var questionToCall: Duration?
    var stubDuration: Duration?
    var callToFirstWordAfter: Duration?

    var carriesAnswer: Bool { text.contains("40") && text.contains("71") }

    /// The loop's own price, per piece, after the first: the number that
    /// stays comparable when two replies differ in length.
    var decodeMsPerPiece: Double {
        guard pieces > 1 else { return 0 }
        return (toolSpikeMsDouble(total) - toolSpikeMsDouble(firstToken)) / Double(pieces - 1)
    }

    /// The columns every table shares: first token, total, stop, chars,
    /// pieces, decode ms/piece.
    var row: String {
        if let failure { return "failed: \(failure) | | | | | " }
        return "\(toolSpikeMs(firstToken)) ms | \(toolSpikeMs(total)) ms | \(stop.map { "\($0)" } ?? "—") "
            + "| \(text.count) | \(pieces) | " + String(format: "%.2f", decodeMsPerPiece)
    }

    /// The tool columns: called, question→call, the stub, call→first word.
    var toolRow: String {
        let called = calls == 0 ? "no" : (calls == 1 ? "yes" : "yes ×\(calls)")
        let entered = questionToCall.map { "\(toolSpikeMs($0)) ms" } ?? "—"
        let stub = stubDuration.map { "\(toolSpikeMicros($0)) µs" } ?? "—"
        let after = callToFirstWordAfter.map { "\(toolSpikeMs($0)) ms" } ?? "—"
        return "\(called) | \(entered) | \(stub) | \(after)"
    }
}

/// One reply, drained by hand so the first token and the first word
/// AFTER the stub answered are both seen — `reply(to:)` hides both.
@MainActor
private func toolSpikeAsk(mind: MLXReplyGenerator, question: String,
                          stub: ToolSpikeStub, clock: ContinuousClock) async -> ToolSpikeOutcome {
    stub.reset()
    var outcome = ToolSpikeOutcome()
    let start = clock.now
    var sawFirst = false
    do {
        let run = try await mind.openReply(to: ReplyContext(
            transcript: question, options: GenerationOptions(temperature: 0)))
        for await update in run.updates {
            switch update {
            case .token(let token):
                if !sawFirst { sawFirst = true; outcome.firstToken = start.duration(to: clock.now) }
                outcome.pieces += 1
                if outcome.callToFirstWordAfter == nil, let entered = stub.enteredAt {
                    outcome.callToFirstWordAfter = entered.duration(to: clock.now)
                }
                outcome.text += token
            case .finished(let stop):
                outcome.stop = stop
            case .failed(let failure):
                outcome.failure = failure.description
            }
        }
    } catch {
        outcome.failure = "\(error)"
    }
    outcome.total = start.duration(to: clock.now)
    outcome.calls = stub.calls
    outcome.questionToCall = stub.enteredAt.map { start.duration(to: $0) }
    outcome.stubDuration = stub.duration
    return outcome
}

// MARK: - arithmetic

private func toolSpikeArgument(_ prefix: String, in arguments: [String]) -> String? {
    arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

private func toolSpikeMsDouble(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15
}

private func toolSpikeMs(_ duration: Duration) -> Int {
    Int(toolSpikeMsDouble(duration).rounded())
}

private func toolSpikeMicros(_ duration: Duration) -> Int {
    Int((Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) * 1e-12).rounded())
}

private func toolSpikeSigned(_ ms: Int) -> String { ms >= 0 ? "+\(ms)" : "\(ms)" }

/// The median, not the mean: one run that hit a page fault should not
/// move a number five other runs agree on.
private func toolSpikeMedian(_ durations: [Duration]) -> Duration {
    guard !durations.isEmpty else { return .zero }
    let sorted = durations.sorted()
    return sorted[sorted.count / 2]
}

private func toolSpikeMedianDouble(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
