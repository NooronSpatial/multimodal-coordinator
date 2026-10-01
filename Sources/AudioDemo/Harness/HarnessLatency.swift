import Foundation
import MultiModalKit
import Synchronization

// THE HARNESS'S REPORTER (5d, SPEC §225/4, AC-342): every turn's timeline and
// every interruption, printed as it comes and kept for the summary; and every
// reply's pauses, as `ListeningHost` hears them.

final class HarnessLatency: LatencyReporter, Sendable {
    struct Kept {
        var timelines: [TurnTimeline] = []
        var barges: [BargeTimeline] = []
        var pauses: [ReplyPauses] = []
    }

    /// ① — the app's own silence wait (F-26 A): the person's sound stopped
    /// this long before the speech-end decision.
    let hangover: Duration
    private let kept = Mutex(Kept())

    init(hangover: Duration) { self.hangover = hangover }

    // The old two numbers are inside the timelines now (`sinceFinal`, `silence`).
    func turnLatency(_ duration: Duration, turn: Int) {}
    func cancelLatency(_ duration: Duration, turn: Int) {}

    func turnTimeline(_ timeline: TurnTimeline) {
        kept.withLock { $0.timelines.append(timeline) }
        let ear = timeline.earFinish.map { $0.ms } ?? "  ?"
        let felt = timeline.felt(hangover: hangover).map { $0.ms } ?? "?"
        print("⏱  turn \(timeline.turn): ① \(hangover.ms) · ② \(ear) · ③ \(timeline.gate.ms)"
              + " · ④ \(timeline.firstToken.ms) · ⑤ \(timeline.firstSound.ms)  →  felt \(felt) ms")
    }

    func bargeTimeline(_ timeline: BargeTimeline) {
        kept.withLock { $0.barges.append(timeline) }
        print("✋ barge (turn \(timeline.turn) dies): ⑦ window \(timeline.window.ms) · ⑧ silence \(timeline.silence.ms)"
              + "  →  \((timeline.window + timeline.silence).ms) ms from your first sound")
    }

    /// `ListeningHost`'s `heard`: one reply's pauses, when its node is given back.
    func heard(_ pauses: ReplyPauses) {
        kept.withLock { $0.pauses.append(pauses) }
        let first = pauses.leadingQuiet.map { " · quiet before the first word \($0.ms) ms" } ?? " · it never sounded"
        print("⏸  reply pauses: \(pauses.gaps) over 300 ms · longest \(pauses.longest.ms) ms" + first)
    }

    /// The medians, stage by stage (AC-342).
    func summary() -> String {
        let kept = kept.withLock { $0 }
        let spoken = kept.timelines
        func row(_ name: String, _ values: [Duration]) -> String {
            guard let middle = Self.median(values) else { return "  \(name)  —" }
            let sorted = values.sorted()
            return "  \(name)  median \(middle.ms) ms · min \(sorted[0].ms) · max \(sorted[sorted.count - 1].ms)"
                + " · n \(values.count)"
        }
        var lines = ["", "════ THE TURN TIMELINE — \(spoken.count) spoken turns, \(kept.barges.count) barges ════"]
        lines.append("  ① silence wait     \(hangover.ms) ms (the app's hangover, every turn)")
        lines.append(row("② ear finish ", spoken.compactMap(\.earFinish)))
        lines.append(row("③ reply gate ", spoken.map(\.gate)))
        lines.append(row("④ first token", spoken.map(\.firstToken)))
        lines.append(row("⑤ first sound", spoken.map(\.firstSound)))
        lines.append(row("   FELT PAUSE ", spoken.compactMap { $0.felt(hangover: hangover) }))
        lines.append(contentsOf: Self.toTheFirstWord(spoken, kept.pauses, hangover: hangover, row: row))
        lines.append(row("⑦ barge window", kept.barges.map(\.window)))
        lines.append(row("⑧ to silence ", kept.barges.map(\.silence)))
        let gaps = kept.pauses.map(\.gaps)
        lines.append("  ⑥ pauses inside answers: \(gaps.reduce(0, +)) over 300 ms in \(gaps.count) replies"
                     + " · replies with one or more: \(gaps.filter { $0 > 0 }.count)")
        lines.append(row("⑥ longest pause", kept.pauses.map(\.longest)))
        return lines.joined(separator: "\n")
    }

    /// THE FELT PAUSE TO THE FIRST WORD (5d piece 2, F-35 A): ⑤ is stamped
    /// when the player starts, and the reply may still hold quiet before its
    /// first word. The k-th spoken turn is the k-th reply that sounded; if the
    /// two counts differ (a reply cut after its stamp, before any audible
    /// sample), the pairing is not trusted and the rows say so.
    static func toTheFirstWord(_ spoken: [TurnTimeline], _ pauses: [ReplyPauses], hangover: Duration,
                               row: (String, [Duration]) -> String) -> [String] {
        let leads = pauses.compactMap(\.leadingQuiet)
        var lines = [row("   quiet before the 1st word", leads)]
        guard leads.count == spoken.count else {
            lines.append("   FELT, TO THE FIRST WORD  — not paired: \(spoken.count) spoken turns,"
                         + " \(leads.count) replies that sounded")
            return lines
        }
        let felt = zip(spoken, leads).compactMap { timeline, lead in
            timeline.felt(hangover: hangover).map { $0 + lead }
        }
        lines.append(row("   FELT, TO THE FIRST WORD", felt))
        return lines
    }

    static func median(_ values: [Duration]) -> Duration? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

extension Duration {
    /// Whole milliseconds, for a line a person reads.
    var ms: String {
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) * 1e-15
        return String(format: "%.0f", milliseconds)
    }
}
