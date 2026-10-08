import Foundation
import MultiModalKit

// 5d (SPEC §225/3): the WHOLE pause, stage by stage — on screen, and in the
// log a person shares after a session.
//
//   you stop ─① hangover─▶ end ─② ear─▶ final ─③ gate─▶ opened ─④ mind─▶ token ─⑤ mouth─▶ first sound
//   interrupting: your first sound ─⑦ window─▶ accepted ─⑧ silence─▶ quiet
//   ⑥ inside an answer: the silences the person hears, counted per reply

extension TranscribeModel {
    /// ① — this app's VAD hangover. The pipeline builds `hangoverFrames` from
    /// this one number, so the felt pause and the VAD cannot drift apart.
    static let hangoverMilliseconds = 300

    /// A host that LISTENS to what it plays (F-27 A): each reply's pauses
    /// come back here, whichever mouth speaks.
    func listening(to host: any PlaybackHost) -> ListeningHost {
        ListeningHost(wrapping: host) { [weak self] pauses in
            Task { @MainActor in self?.record(pauses: pauses) }
        }
    }

    func record(timeline: TurnTimeline) {
        timelines.append(timeline)
        if let felt = timeline.felt(hangover: .milliseconds(Self.hangoverMilliseconds)) {
            show(feltPause: felt)
            feltPauseIsWhole = true
        } else {
            show(feltPause: timeline.sinceFinal)
            feltPauseIsWhole = false
        }
    }

    func record(barge: BargeTimeline) { barges.append(barge) }

    func record(candidate: BargeCandidate) { bargeCandidates.append(candidate) }

    func record(pauses: ReplyPauses) { replyPauses.append(pauses) }

    /// The log's timeline section: every row, then the medians.
    var timelineLog: String {
        let hangover = Duration.milliseconds(Self.hangoverMilliseconds)
        var out = "\n## timeline (5d)\n\n```\n"
        out += "device: \(DeviceLine.current)\n"
        out += "① silence wait: \(Self.hangoverMilliseconds) ms (this app's VAD hangover)\n"
        for timeline in timelines {
            let ear = timeline.earFinish.map(Self.ms) ?? "?"
            let felt = timeline.felt(hangover: hangover).map(Self.ms) ?? "?"
            out += "turn \(timeline.turn): ② \(ear) · ③ \(Self.ms(timeline.gate)) · ④ \(Self.ms(timeline.firstToken))"
            out += " · ⑤ \(Self.ms(timeline.firstSound)) → felt \(felt) ms\n"
        }
        for barge in barges {
            out += "barge (turn \(barge.turn) dies): ⑦ \(Self.ms(barge.window)) · ⑧ \(Self.ms(barge.silence))"
            out += " → \(Self.ms(barge.window + barge.silence)) ms\n"
        }
        // 5d piece 3 (F-40 A): every sound over a reply, as the window judged
        // it — how long it stayed LOUD tells a leak from a person.
        for candidate in bargeCandidates {
            out += "candidate over turn \(candidate.turn): loud \(Self.ms(candidate.loudTime)) ms"
            out += String(format: " · peak %.3f", candidate.peak)
            out += " · onset → verdict \(Self.ms(candidate.window)) ms → \(candidate.accepted ? "CUT" : "abandoned")\n"
        }
        for (index, pauses) in replyPauses.enumerated() {
            let first = pauses.leadingQuiet.map { " · quiet before the first word \(Self.ms($0)) ms" }
                ?? " · never sounded"
            out += "reply #\(index + 1): \(pauses.gaps) pauses over 300 ms"
                + " · longest \(Self.ms(pauses.longest)) ms\(first)\n"
        }
        out += "\nmedians · \(timelines.count) spoken turns · \(barges.count) barges · \(replyPauses.count) replies\n"
        out += Self.medianLine("② ear   ", timelines.compactMap(\.earFinish))
        out += Self.medianLine("③ gate  ", timelines.map(\.gate))
        out += Self.medianLine("④ token ", timelines.map(\.firstToken))
        out += Self.medianLine("⑤ sound ", timelines.map(\.firstSound))
        out += Self.medianLine("FELT    ", timelines.compactMap { $0.felt(hangover: hangover) })
        out += firstWordLines(hangover: hangover)
        out += Self.medianLine("⑦ window", barges.map(\.window))
        out += Self.medianLine("⑧ silent", barges.map(\.silence))
        out += Self.medianLine("loud · cut      ", bargeCandidates.filter(\.accepted).map(\.loudTime))
        out += Self.medianLine("loud · abandoned", bargeCandidates.filter { !$0.accepted }.map(\.loudTime))
        out += Self.medianLine("⑥ longest pause", replyPauses.map(\.longest))
        out += "⑥ replies with a pause over 300 ms: \(replyPauses.filter { $0.gaps > 0 }.count)\n```\n"
        return out
    }

    /// THE FELT PAUSE TO THE FIRST WORD (5d piece 2, F-35 A): the k-th
    /// spoken turn is the k-th reply that sounded — trusted only when the
    /// two counts agree, and said so when they do not.
    private func firstWordLines(hangover: Duration) -> String {
        let leads = replyPauses.compactMap(\.leadingQuiet)
        var out = Self.medianLine("1st-word quiet", leads)
        guard leads.count == timelines.count else {
            return out + "TO 1st WORD  — not paired: \(timelines.count) spoken turns,"
                + " \(leads.count) replies that sounded\n"
        }
        out += Self.medianLine("TO 1st WORD", zip(timelines, leads).compactMap { timeline, lead in
            timeline.felt(hangover: hangover).map { $0 + lead }
        })
        return out
    }

    private static func medianLine(_ name: String, _ values: [Duration]) -> String {
        guard !values.isEmpty else { return "\(name)  —\n" }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return "\(name)  median \(ms(median)) · min \(ms(sorted[0])) · max \(ms(sorted[sorted.count - 1]))\n"
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.0f", Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) * 1e-15)
    }
}
