import FoundationModels
import Observation
import SwiftUI

/// THE MIND PROBE (SPEC AC-110 + AC-111) — a measurement, NOT the adapter.
///
/// 4f's spec forbids adapter code until two numbers exist, and this file
/// is how the phone produces them:
///
/// - **AC-110**: which of the three `UnavailableReason` cases this device
///   is actually in, read from the API rather than from Settings' word.
/// - **AC-111**: the stream's SHAPE. `streamResponse` yields cumulative
///   `Snapshot`s, and `SpeechPhraser` concatenates VERBATIM — so the
///   adapter must diff, and the diff is only safe if every snapshot
///   strictly EXTENDS the one before it. If the model can revise text we
///   already handed to a mouth, we have already said it. Audio cannot be
///   unsaid. F-1 is ruled by what this measures, not by an argument.
///
/// On-screen and SHARED AS TEXT, because a phone has no stderr — the 4e
/// lesson that cost a field trip — and because a verdict that comes back
/// as a screenshot cannot be pasted into INSTRUMENTS.md.
///
/// Runs on the main actor while the app is IDLE, and the share text says
/// so: latency numbers here are indicative, not publishable. The real
/// adapter gets its own actor, away from anything audio-adjacent.
@MainActor
@Observable
final class MindProbe {

    struct PromptResult: Identifiable {
        let id: Int
        let prompt: String
        var snapshots = 0
        var firstMs: Double = 0
        var totalMs: Double = 0
        var cumulative = false          // lengths never shrink
        var strictlyExtending = false   // new.hasPrefix(old), every pair
        var scalarExtending = false     // same, at unicode-scalar level
        var revisions: [(step: Int, was: String, now: String)] = []
        var finalText = ""
        var failure: String?

        /// A snapshot that extends at the SCALAR level but not the
        /// character level ended mid-grapheme — a diff on characters
        /// would stutter there.
        var graphemeSplitSuspected: Bool { scalarExtending && !strictlyExtending }
    }

    /// AC-110's answer, as the enum says it — with the `@unknown default`
    /// AC-114 demands, because `UnavailableReason` is NON-frozen.
    private(set) var availabilityLine = "not read yet"
    private(set) var isAvailable = false
    private(set) var status: String?
    private(set) var results: [PromptResult] = []
    private(set) var shareText = ""

    func readAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            availabilityLine = "available"
            isAvailable = true
        case .unavailable(let reason):
            isAvailable = false
            switch reason {
            case .deviceNotEligible:
                availabilityLine = "unavailable — this device cannot run the model"
            case .appleIntelligenceNotEnabled:
                availabilityLine = "unavailable — Apple Intelligence is switched off in Settings"
            case .modelNotReady:
                availabilityLine = "unavailable — the model is still downloading; try again later"
            @unknown default:
                availabilityLine = "unavailable — a reason this app does not know yet"
            }
        }
    }

    /// One prompt asks for length: many snapshots make prefix violations
    /// and revisions more likely to SHOW, which is the point of a probe.
    private static let prompts = [
        "What is the capital of France? Answer in two short sentences.",
        "Count from one to ten in words.",
        "Say three short sentences about the sea.",
        "Explain in four sentences why the sky is blue."
    ]

    func run() async {
        readAvailability()
        guard isAvailable else { status = nil; return }
        results = []
        shareText = ""
        let clock = ContinuousClock()

        for (index, prompt) in Self.prompts.enumerated() {
            status = "measuring \(index + 1)/\(Self.prompts.count)…"
            // A fresh session per prompt — the F-2 = A shape, and it also
            // keeps one prompt's context from touching the next.
            let session = LanguageModelSession()
            var row = PromptResult(id: index, prompt: prompt)
            var snapshots: [String] = []
            let birth = clock.now
            var firstAt: ContinuousClock.Instant?

            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    if firstAt == nil { firstAt = clock.now }
                    snapshots.append(snapshot.content)
                }
            } catch {
                // The full mapping is AC-114 and belongs to the adapter;
                // the probe just refuses to hide the case name.
                row.failure = String(describing: error)
            }
            let end = clock.now

            row.snapshots = snapshots.count
            row.firstMs = Self.ms(birth.duration(to: firstAt ?? end))
            row.totalMs = Self.ms(birth.duration(to: end))
            row.finalText = snapshots.last ?? ""
            let lengths = snapshots.map(\.count)
            row.cumulative = zip(lengths, lengths.dropFirst()).allSatisfy { $0 <= $1 }
            row.strictlyExtending = true
            row.scalarExtending = true
            for i in 1..<max(1, snapshots.count) where i < snapshots.count {
                let was = snapshots[i - 1], now = snapshots[i]
                if !now.hasPrefix(was) {
                    row.strictlyExtending = false
                    row.revisions.append((i, was, now))
                }
                if !Array(now.unicodeScalars).starts(with: Array(was.unicodeScalars)) {
                    row.scalarExtending = false
                }
            }
            results.append(row)
        }
        status = nil
        shareText = buildShareText()
    }

    /// The whole trace as markdown, so the measurement leaves the phone
    /// as data. Every snapshot is included: a verdict without its
    /// evidence is an adjective.
    private func buildShareText() -> String {
        var out = "# AC-110/AC-111 — Foundation Models stream shape (iPhone)\n\n"
        out += "availability: \(availabilityLine)\n"
        out += "context size: \(SystemLanguageModel.default.contextSize) tokens\n"
        out += "caveat: measured on the main actor of an idle app — "
        out += "shape verdicts are solid, latency is indicative only\n\n"
        for row in results {
            out += "## prompt \(row.id): \(row.prompt)\n"
            if let failure = row.failure { out += "THREW: \(failure)\n" }
            out += String(format: "snapshots %d · first %.0f ms · total %.0f ms\n",
                          row.snapshots, row.firstMs, row.totalMs)
            if row.failure != nil || row.snapshots < 2 {
                out += "shape: NO DATA — under two snapshots there is no pair to compare\n"
            } else {
                out += "cumulative: \(row.cumulative) · strictly extending: \(row.strictlyExtending)"
                out += " · grapheme split suspected: \(row.graphemeSplitSuspected)\n"
            }
            for r in row.revisions {
                out += "REVISION at \(r.step):\n  was: \(r.was)\n  now: \(r.now)\n"
            }
            out += "final: \(row.finalText)\n\n"
        }
        let measured = results.filter { $0.failure == nil && $0.snapshots >= 2 }
        let allExtend = !measured.isEmpty && measured.allSatisfy(\.strictlyExtending)
        if measured.count < results.count {
            out += "NOTE: only \(measured.count) of \(results.count) prompts produced a measurable stream.\n"
        }
        out += measured.isEmpty
            ? "VERDICT this run: NO DATA — nothing streamed, so the shape question is UNANSWERED. "
            + "(The availability line said 'available'; if this text is being read, that line LIED — "
            + "record it: availability is a necessary gate, not a sufficient one.)\n"
            : allExtend
            ? "VERDICT this run: every snapshot strictly extended its predecessor. "
            + "(One run is evidence, not proof — 'none observed' is not 'cannot happen'.)\n"
            : "VERDICT this run: NOT strictly extending — see the revisions above. "
            + "F-1 = A's plain diff is UNSAFE on this device.\n"
        return out
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
    }
}

/// The probe's screen presence — beside the bake-off section, same shape:
/// run, read, share.
struct MindProbeSection: View {
    @Bindable var probe: MindProbe

    var body: some View {
        Section("Mind probe — AC-110/AC-111, before any adapter") {
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
                    Label("Measure the stream shape", systemImage: "brain")
                }
            }
            ForEach(probe.results) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.prompt).font(.caption2).foregroundStyle(.secondary)
                    if let failure = row.failure {
                        Text(failure).font(.caption2).foregroundStyle(.red)
                    }
                    Text(String(format: "%d snapshots · first %.0f ms · total %.0f ms",
                                row.snapshots, row.firstMs, row.totalMs))
                        .font(.caption2.monospacedDigit())
                    // A VERDICT NEEDS EVIDENCE. The first simulator run
                    // threw with ZERO snapshots and this line still said
                    // "strictly extending ✓" in green — vacuously true, the
                    // lying-instrument class this repo hunts. Under two
                    // snapshots there is no pair to compare, so say NO DATA.
                    if row.failure != nil || row.snapshots < 2 {
                        Text("shape: no data — nothing streamed")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(row.strictlyExtending
                             ? "strictly extending ✓"
                             : "⚠️ REVISED already-emitted text — \(row.revisions.count)×")
                            .font(.caption2.bold())
                            .foregroundStyle(row.strictlyExtending ? .green : .red)
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
