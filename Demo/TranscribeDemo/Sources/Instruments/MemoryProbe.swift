import Foundation
import MultiModalKit
import MultiModalKitMLX
import Observation
import SwiftUI

/// THE MEMORY PROBE (4r, AC-197 + AC-198) — what remembering COSTS.
///
/// The milestone's central claim is not "it remembers"; the field log
/// closed that in words (INSTRUMENTS §58). It is that **history is
/// prefill**: every remembered exchange lengthens the prompt the mind
/// must read before its first token, and the felt pause is the number
/// this project has spent three milestones shortening.
///
/// §58 could not answer it, and said so in a list. The questions differed,
/// thermal moved nominal → fair exactly where the step appeared, and the
/// depth never reached the lever. This probe removes all three:
///
/// - **one question**, asked byte for byte identically at every depth, so
///   the only thing that changes is how much past sits in front of it;
/// - **the depths are built, not waited for** — the filler conversation
///   is fixed text, so depth 8 exists in the first minute instead of the
///   twentieth;
/// - **sixteen tokens per draw and then a cancel.** The reply's CONTENT
///   is not the measurement, and generating four full replies at three
///   depths would heat the phone into the confound this exists to remove.
///
/// **What it measures, stated so it cannot be over-read: the MIND's first
/// token, not the first audible word.** The mouth sits after this and its
/// cost does not depend on history, so the difference between rows is the
/// difference in the felt pause — but the absolute numbers are smaller
/// than what a person hears.
///
/// It is a phone instrument and has no Mac twin on purpose. §55 and §56
/// measured this Mac at 3-6× the phone's speed; a prefill curve taken
/// here would be a different machine's answer to Ryad's question.
@MainActor
@Observable
final class MemoryProbe {

    /// One draw. A named type rather than a tuple so nine rows of numbers
    /// cannot be read in the wrong order.
    struct Row: Identifiable {
        let id: Int
        let depth: Int
        let draw: Int
        let historyCharacters: Int
        let firstTokenMs: Double
        let thermal: String
        let activeMB: Int
        let peakMB: Int
        let failure: String?
    }

    private(set) var rows: [Row] = []
    private(set) var status: String?
    private(set) var shareText = ""

    /// Off, and two depths above it. Eight is the top because the shipped
    /// budget (4,000 characters) must not be what bites — the DEPTH is the
    /// axis being measured, and a budget cutting in halfway up would make
    /// two of these rows the same row wearing different labels.
    static let depths = [0, 4, 8]
    /// Three draws, because one number is an anecdote. First-token time on
    /// a phone moves with whatever else the OS is doing.
    static let draws = 3

    /// THE MEASURED QUESTION, and it is deliberately answerable without
    /// any history at all. A question that leaned on the past would be
    /// answered differently at depth 0, and a different answer is a
    /// different amount of work.
    static let question = "Name one ocean."

    /// The filler conversation, sized like a real one: §58's turns ran
    /// about 30 characters of question and 140 of reply, and these match.
    /// Fixed text, so every depth at every draw is byte for byte the same
    /// past — the one thing that must not vary between rows.
    static let filler: [ConversationTurn] = [
        .init(said: "Tell me about the history of Algeria.",
              replied: "Algeria's history is marked by ancient civilizations, Roman conquest, "
                     + "Arab rule, Ottoman influence, French colonization, and independence in 1962."),
        .init(said: "What is the capital of this country?",
              replied: "The capital of Algeria is Algiers, on the Mediterranean coast."),
        .init(said: "And the population there?",
              replied: "The population of Algeria is approximately 44 million as of 2023."),
        .init(said: "Which languages are spoken?",
              replied: "Arabic and Berber are official, and French is widely used in business "
                     + "and education."),
        .init(said: "Is it a large country?",
              replied: "Algeria is the largest country in Africa by land area, most of which "
                     + "is Sahara desert."),
        .init(said: "What is the weather like in summer?",
              replied: "The coast is warm and humid in summer, while the interior and the "
                     + "desert become extremely hot."),
        .init(said: "Name a famous dish.",
              replied: "Couscous is the best known Algerian dish, usually served with meat "
                     + "and vegetables."),
        .init(said: "When did the war of independence begin?",
              replied: "The Algerian war of independence began in 1954 and ended with "
                     + "independence in 1962.")
    ]

    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "unknown"
        }
    }

    /// Runs the sweep. The model must already be installed; this probe
    /// loads and WARMS it first, and throws that warm draw away.
    func run(model: LocalMindModel, instructions: String) async {
        guard status == nil else { return }
        rows = []
        shareText = ""
        status = "loading the mind…"

        guard model.modelInstalled() else {
            status = nil
            shareText = "the local mind is not installed — nothing to measure."
            return
        }
        // Sixteen tokens is all this needs, and the reason is thermal, not
        // impatience: a probe that heats the phone changes the number it
        // came to read.
        let generator = MLXReplyGenerator(model: model, instructions: instructions,
                                          maxTokens: 16)
        do { try await model.ensureModel() } catch {
            status = nil
            shareText = "the mind would not load: \(error)"
            return
        }

        // THE WARM DRAW, THROWN AWAY. Loading is not warming (§25): with
        // the weights resident the first generation still pays Metal
        // pipeline warm-up. Charging that to depth 0 would print a curve
        // that slopes the wrong way and look like a finding.
        status = "warm-up (discarded)…"
        _ = await firstToken(generator, history: [])

        var identifier = 0
        for depth in Self.depths {
            let history = Array(Self.filler.prefix(depth))
            let characters = history.reduce(0) { $0 + $1.characters }
            for draw in 1...Self.draws {
                status = "depth \(depth), draw \(draw) of \(Self.draws)…"
                let outcome = await firstToken(generator, history: history)
                identifier += 1
                rows.append(Row(
                    id: identifier, depth: depth, draw: draw,
                    historyCharacters: characters,
                    firstTokenMs: outcome.milliseconds,
                    thermal: Self.thermalName,
                    activeMB: MLXRuntime.activeMemoryBytes / 1_048_576,
                    peakMB: MLXRuntime.peakMemoryBytes / 1_048_576,
                    failure: outcome.failure))
            }
        }
        status = nil
        shareText = report()
    }

    private struct Outcome {
        var milliseconds: Double = 0
        var failure: String?
    }

    /// One draw: open a reply, stop the clock on the FIRST token, and kill
    /// the run. Nothing after the first token is part of this measurement.
    private func firstToken(_ generator: MLXReplyGenerator,
                            history: [ConversationTurn]) async -> Outcome {
        let context = ReplyContext(transcript: Self.question, history: history)
        let start = ContinuousClock.now
        do {
            let run = try await generator.openReply(to: context)
            for await update in run.updates {
                switch update {
                case .token:
                    // The clock is read ONCE. The first version read it
                    // twice — seconds from one call, attoseconds from
                    // another — which is two different instants added
                    // together and would have drifted by however long the
                    // second read took.
                    let elapsed = ContinuousClock.now - start
                    await run.cancel()
                    return Outcome(milliseconds: Self.ms(elapsed))
                case .failed(let why):
                    return Outcome(failure: why)
                case .finished:
                    // A reply with no token at all. Rare, and it must not
                    // be recorded as a fast one.
                    return Outcome(failure: "finished with no token")
                }
            }
            return Outcome(failure: "the stream ended without a token")
        } catch {
            return Outcome(failure: String(describing: error))
        }
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) * 1e-15
    }

    /// The share text. Markdown, because a verdict that comes back as a
    /// screenshot cannot be pasted into INSTRUMENTS.md — the 4e lesson.
    private func report() -> String {
        var out = "# Memory probe — AC-197 / AC-198\n\n"
        out += "question asked at every depth: \"\(Self.question)\"\n"
        out += "draws per depth: \(Self.draws) · reply capped at 16 tokens then cancelled\n"
        out += "measures the MIND's first token, not the first audible word\n\n"
        out += "| depth | history chars | draw | first token | thermal | MLX active | MLX peak |\n"
        out += "|---|---|---|---|---|---|---|\n"
        for row in rows {
            let first = row.failure.map { "FAILED — \($0)" }
                ?? String(format: "%.0f ms", row.firstTokenMs)
            out += "| \(row.depth == 0 ? "off" : "\(row.depth)") | \(row.historyCharacters) "
                + "| \(row.draw) | \(first) | \(row.thermal) "
                + "| \(row.activeMB) MB | \(row.peakMB) MB |\n"
        }
        out += "\n## medians\n\n"
        for depth in Self.depths {
            let good = rows.filter { $0.depth == depth && $0.failure == nil }
                .map(\.firstTokenMs).sorted()
            guard !good.isEmpty else {
                out += "- depth \(depth): no successful draw\n"
                continue
            }
            out += String(format: "- depth %@: median %.0f ms (of %d draws)\n",
                          depth == 0 ? "off" : "\(depth)", good[good.count / 2], good.count)
        }
        out += "\n## read this against\n\n"
        out += "- The thermal column. If it is not the same word on every row, the\n"
        out += "  sweep measured two machines and the difference is not history.\n"
        out += "- The shipped character budget is 4,000 and the deepest row here is\n"
        out += "  \(Self.filler.reduce(0) { $0 + $1.characters }) characters, so the budget never bit:\n"
        out += "  every row differs by DEPTH alone, which is what AC-197 asked.\n"
        out += "- The mouth is not in these numbers. It sits after the mind and its\n"
        out += "  cost does not move with history, so the DIFFERENCE between rows\n"
        out += "  carries to the felt pause while the absolute values do not.\n"
        return out
    }
}

/// The probe's own screen. Same shape as `MindProbeSection`, including the
/// share link — a number that cannot leave the phone is a number nobody
/// can put in INSTRUMENTS.md.
struct MemoryProbeSection: View {
    @Bindable var probe: MemoryProbe
    let model: LocalMindModel
    let instructions: String

    var body: some View {
        Section("Memory probe — AC-197: what remembering costs") {
            if let status = probe.status {
                Label(status, systemImage: "hourglass").foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await probe.run(model: model, instructions: instructions) }
                } label: {
                    Label("Sweep off · 4 · 8", systemImage: "clock.arrow.circlepath")
                }
            }
            ForEach(probe.rows) { row in
                HStack {
                    Text(row.depth == 0 ? "off" : "\(row.depth) turns")
                        .font(.caption2.monospaced())
                        .frame(width: 64, alignment: .leading)
                    if let failure = row.failure {
                        Text(failure).font(.caption2).foregroundStyle(.red)
                    } else {
                        Text(String(format: "%.0f ms", row.firstTokenMs))
                            .font(.caption2.monospacedDigit().bold())
                        Spacer()
                        // The thermal word travels WITH the number, never
                        // in a header. §58's step appeared exactly where
                        // thermal moved, and a reader who cannot see that
                        // beside the row will read it as history.
                        Text("\(row.thermal) · \(row.peakMB) MB")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !probe.shareText.isEmpty {
                ShareLink(item: probe.shareText) {
                    Label("Share the sweep (markdown)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}
