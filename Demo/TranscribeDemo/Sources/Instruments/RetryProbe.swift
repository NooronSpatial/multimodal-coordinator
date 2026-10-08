import FoundationModels
import Observation
import SwiftUI
import Synchronization

/// PROBE-R (5b, SPEC §213, D-122) — a measurement, NOT the retry.
///
/// Twice on the diet app's phone the Apple mind ran its tools and then
/// failed while WRITING the reply, with an error nothing public names.
/// §213's retry must RE-ASK — every `respond` / `streamResponse` takes a
/// prompt — and what the real model does when re-asked is this probe's
/// question. F-18 is ruled A and stands until this says otherwise; B and C
/// are measured beside it, so the ruling is checked against its
/// alternatives and not only against itself.
///
///     attempt 1  fresh session · the prompt · log_weight's body RUNS
///                (counted), then the turn FAILS — injected, at the diet
///                app's point: after the tool, before any word
///     A replay   fresh session · the same words · a repeat of the call is
///                answered from its RECORD — does a body run again? is a
///                reply written?
///     B seeded   a session BORN holding the call and its output · asked
///                the same words again
///     C empty    the same seeded shape · asked with an empty prompt
///
/// The vendor's own failure cannot be summoned, so the fault is the
/// probe's: the tool's body runs and records, THEN throws. Talks to the
/// vendor directly, like `MindProbe`: it measures the model, not the
/// library's keeper. Shared as text, because a phone has no stderr.
@MainActor
@Observable
final class RetryProbe {

    struct Attempt: Identifiable {
        var id: String { "\(trial)·\(variant)" }
        let trial: Int
        let variant: String
        /// Bodies that ran IN THIS ATTEMPT — R-1's rule is that a retry
        /// adds none for a call already made.
        var bodyRuns = 0
        /// Calls answered from a record in this attempt.
        var fromRecord = 0
        var reply = ""
        var firstWordMs: Double?
        var totalMs: Double = 0
        var failure: String?
    }

    static let instructions = "You keep a person's weight log. When they tell you their weight, "
        + "call log_weight with it, then confirm in one short sentence."
    static let prompt = "Log 84 kilos, please."
    static let trials = 3

    private(set) var availabilityLine = "not read yet"
    private(set) var isAvailable = false
    private(set) var status: String?
    private(set) var attempts: [Attempt] = []
    private(set) var shareText = ""

    func readAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            availabilityLine = "available"
            isAvailable = true
        case .unavailable(let reason):
            availabilityLine = "unavailable — \(reason)"
            isAvailable = false
        }
    }

    func run() async {
        readAvailability()
        guard isAvailable else { return }
        attempts = []
        shareText = ""
        for trial in 1...Self.trials {
            let ledger = RetryLedger()

            status = "trial \(trial)/\(Self.trials) · 1 · the turn that fails…"
            ledger.set(memo: false, failAfterRun: true)
            attempts.append(await measure("1 · fails after the tool", trial: trial, ledger: ledger,
                                          prompt: Self.prompt) {
                LanguageModelSession(tools: [ProbeLogWeight(ledger: ledger)], instructions: Self.instructions)
            })
            // The model answered without calling the tool: nothing ran,
            // so there is nothing a retry could run twice. The trial is
            // void and says so in the trace.
            guard let record = ledger.firstRecord else { continue }

            ledger.set(memo: true, failAfterRun: false)
            status = "trial \(trial)/\(Self.trials) · A · replay…"
            attempts.append(await measure("A · replay", trial: trial, ledger: ledger, prompt: Self.prompt) {
                LanguageModelSession(tools: [ProbeLogWeight(ledger: ledger)], instructions: Self.instructions)
            })
            status = "trial \(trial)/\(Self.trials) · B · seeded, same words…"
            attempts.append(await measure("B · seeded, same words", trial: trial, ledger: ledger,
                                          prompt: Self.prompt) {
                LanguageModelSession(tools: [ProbeLogWeight(ledger: ledger)],
                                     transcript: Self.seeded(kg: record.kg, words: record.words))
            })
            status = "trial \(trial)/\(Self.trials) · C · seeded, empty prompt…"
            attempts.append(await measure("C · seeded, empty prompt", trial: trial, ledger: ledger,
                                          prompt: "") {
                LanguageModelSession(tools: [ProbeLogWeight(ledger: ledger)],
                                     transcript: Self.seeded(kg: record.kg, words: record.words))
            })
        }
        status = nil
        shareText = buildShareText()
    }

    /// One attempt: a session made the given way, asked `prompt`, timed,
    /// and its tool counts read as the DIFFERENCE this attempt made.
    private func measure(_ variant: String, trial: Int, ledger: RetryLedger, prompt: String,
                         session make: () -> LanguageModelSession) async -> Attempt {
        var attempt = Attempt(trial: trial, variant: variant)
        let before = ledger.counts
        let clock = ContinuousClock()
        let start = clock.now
        let session = make()
        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                if attempt.firstWordMs == nil, !snapshot.content.isEmpty {
                    attempt.firstWordMs = Self.ms(start.duration(to: clock.now))
                }
                attempt.reply = snapshot.content
            }
        } catch {
            attempt.failure = String(describing: error)
        }
        attempt.totalMs = Self.ms(start.duration(to: clock.now))
        let after = ledger.counts
        attempt.bodyRuns = after.bodyRuns - before.bodyRuns
        attempt.fromRecord = after.fromRecord - before.fromRecord
        return attempt
    }

    /// The shape of F-18 B and C: a session born holding the prompt, the
    /// call attempt 1's model wrote, and the output it was given.
    static func seeded(kg: Double, words: String) -> Transcript {
        let call = Transcript.ToolCall(id: "probe-call", toolName: ProbeLogWeight.toolName,
                                       arguments: GeneratedContent(properties: ["kg": kg]))
        return Transcript(entries: [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
            .toolCalls(Transcript.ToolCalls(id: "probe-calls", [call])),
            .toolOutput(Transcript.ToolOutput(id: "probe-call", toolName: ProbeLogWeight.toolName,
                                              segments: [.text(Transcript.TextSegment(content: words))]))
        ])
    }

    private func buildShareText() -> String {
        var out = "# PROBE-R — the reply retry's vendor fact (5b §213, F-18)\n\n"
        out += "availability: \(availabilityLine)\n"
        out += "device: \(DeviceLine.current)\n"
        out += "prompt: \(Self.prompt)\n"
        out += "caveat: main actor of an idle app — the counts are solid, the times indicative\n\n"
        for trial in 1...Self.trials {
            out += "## trial \(trial)\n"
            let rows = attempts.filter { $0.trial == trial }
            if rows.count == 1 { out += "VOID: the model answered without calling the tool\n" }
            for row in rows {
                out += "- \(row.variant): bodies run \(row.bodyRuns) · from record \(row.fromRecord)"
                out += row.firstWordMs.map { String(format: " · first word %.0f ms", $0) } ?? " · no word"
                out += String(format: " · total %.0f ms\n", row.totalMs)
                if let failure = row.failure { out += "  threw: \(failure)\n" }
                if !row.reply.isEmpty { out += "  said: \(row.reply)\n" }
            }
            out += "\n"
        }
        out += verdict()
        return out
    }

    /// F-18 A holds in a trial when the replay ran NO body, wrote a reply,
    /// and did not fail. One run is evidence, not proof.
    private func verdict() -> String {
        let replays = attempts.filter { $0.variant.hasPrefix("A") }
        guard !replays.isEmpty else {
            return "VERDICT: NO DATA — no trial reached the replay (the model never called the tool).\n"
        }
        let held = replays.filter { $0.bodyRuns == 0 && !$0.reply.isEmpty && $0.failure == nil }
        return held.count == replays.count
            ? "VERDICT this run: F-18 A held in \(held.count) of \(replays.count) trials — "
            + "no body ran twice, and a reply was written every time.\n"
            : "VERDICT this run: F-18 A held in only \(held.count) of \(replays.count) trials — "
            + "see the A rows; F-18 is reopened.\n"
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15
    }
}

// MARK: - the probe's tool, and what it did

/// Every body run and every answer from a record, counted — the numbers
/// R-1's hard rule lives by: a write that ran never runs again.
final class RetryLedger: Sendable {
    struct Counts: Sendable {
        var bodyRuns = 0
        var fromRecord = 0
    }

    enum Step {
        case recorded(String)
        case ran(String, thenFail: Bool)
    }

    private struct State {
        var counts = Counts()
        var records: [Double: String] = [:]
        var memo = false
        var failAfterRun = false
    }

    private let state = Mutex(State())

    /// Attempt 1: the body runs and the turn fails after it. Later
    /// attempts: a repeat is answered from its record.
    func set(memo: Bool, failAfterRun: Bool) {
        state.withLock { $0.memo = memo; $0.failAfterRun = failAfterRun }
    }

    var counts: Counts { state.withLock { $0.counts } }

    /// The call attempt 1 made, if the model made one.
    var firstRecord: (kg: Double, words: String)? {
        state.withLock { $0.records.min { $0.key < $1.key }.map { (kg: $0.key, words: $0.value) } }
    }

    /// One call of the tool: answered from its record when that is on and
    /// the same call was made before; otherwise the body runs, and records.
    func call(kg: Double) -> Step {
        state.withLock { state in
            if state.memo, let words = state.records[kg] {
                state.counts.fromRecord += 1
                return .recorded(words)
            }
            state.counts.bodyRuns += 1
            let whole = kg == kg.rounded() && abs(kg) < 1_000_000
            let words = "Logged \(whole ? String(Int(kg)) : String(kg)) kg."
            state.records[kg] = words
            return .ran(words, thenFail: state.failAfterRun)
        }
    }
}

/// The fault the probe injects: the body ran, then the turn failed.
struct InjectedFailure: Error, CustomStringConvertible {
    var description: String { "PROBE-R: the turn failed on purpose, right after the tool ran" }
}

struct ProbeLogWeight: Tool {
    static let toolName = "log_weight"
    let name = Self.toolName
    let description = "Records the person's weight, in kilograms, in their log."
    let ledger: RetryLedger

    @Generable
    struct Arguments {
        @Guide(description: "The weight in kilograms.")
        let kg: Double
    }

    func call(arguments: Arguments) async throws -> String {
        switch ledger.call(kg: arguments.kg) {
        case .recorded(let words):
            return words
        case .ran(let words, let thenFail):
            if thenFail { throw InjectedFailure() }
            return words
        }
    }
}

// MARK: - the screen

struct RetryProbeSection: View {
    @Bindable var probe: RetryProbe

    var body: some View {
        Section("PROBE-R — the reply retry, before its code (5b §213)") {
            Text(probe.availabilityLine)
                .font(.caption.monospaced())
                .foregroundStyle(probe.isAvailable ? .green : .secondary)
                .onAppear { probe.readAvailability() }
            if let status = probe.status {
                Label(status, systemImage: "hourglass").foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await probe.run() }
                } label: {
                    Label("Run PROBE-R (\(RetryProbe.trials) trials)", systemImage: "arrow.clockwise")
                }
            }
            ForEach(probe.attempts) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("trial \(row.trial) · \(row.variant)").font(.caption2.bold())
                    Text("bodies run \(row.bodyRuns) · from record \(row.fromRecord)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(row.variant.hasPrefix("1") || row.bodyRuns == 0 ? .primary : Color.red)
                    if let failure = row.failure {
                        Text(failure).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !row.reply.isEmpty {
                        Text(row.reply).font(.caption2)
                    }
                }
            }
            if !probe.shareText.isEmpty {
                ShareLink(item: probe.shareText) {
                    Label("Share the full trace (markdown)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

extension View {
    /// PROBE-R's sheet, kept beside the probe: the Bench tab is at the
    /// linter's body-length limit, so it carries one line for it. The
    /// probe itself stays owned by the tab, for `MemoryProbe`'s reason.
    func retryProbeSheet(_ isPresented: Binding<Bool>, probe: RetryProbe) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                List { RetryProbeSection(probe: probe) }
                    .navigationTitle("PROBE-R")
            }
        }
    }
}
