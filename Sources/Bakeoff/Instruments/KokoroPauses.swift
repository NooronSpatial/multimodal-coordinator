// The `kokoro-pauses` instrument (5d piece 2, F-33 A; D-138): the pause
// Kokoro ITSELF makes at each clause mark when it reads a whole sentence —
// the pause the trim keeps where it cuts away the model's own padding.
//
//   swift run -c release bakeoff kokoro-pauses [--kokoro-weights=DIR]
//
// Each sentence holds ONE mark, in its middle, and is synthesized as ONE
// utterance — straight through the vendor, past our phraser, which would
// cut it at that mark. Read on the samples the model returned (no player,
// no mixer), at the SilenceMeter's level:
//
//   [lead quiet][words … ░░░ pause at the mark ░░░ … words][tail quiet]
//
// The pause at the mark is the quiet stretch nearest the mark's own token,
// whose start and end the vendor predicts from its durations (25 ms
// steps). The longest quiet stretch inside the words is printed beside it,
// so a stop consonant's short silence can never be mistaken for the mark's.
import Foundation
import KokoroSwift
import MLX
import MultiModalKitTTS

private let pauseSentences: [(mark: String, texts: [String])] = [
    (",", ["Germany has a long history, shaped by many wars and reunions.",
           "I can help with that, if you tell me a little more.",
           "The first law says energy is conserved, never created.",
           "Grill the chicken first, then slice it into thin strips."]),
    (".", ["I can hear you. Say that again and I will stop.",
           "That is a good question. Let me think about it for a moment.",
           "Algebra uses letters for numbers. It helps us solve equations.",
           "The recipe is ready. Enjoy your lunch with a fresh salad."]),
    ("?", ["Do you mean low carb? I can suggest a simple dinner.",
           "Is that the right city? Tell me and I will check again.",
           "Would you like more detail? I can explain the second law."]),
    ("!", ["Good morning! How can I help you today?",
           "That sounds great! Let me find a recipe for you.",
           "Sure! Here is a simple low carb recipe for lunch."]),
    (":", ["Here is the plan: grill the chicken and steam the spinach.",
           "The answer is simple: energy changes form but never disappears.",
           "I can suggest an idea: an app that tracks your focus time."]),
    (";", ["Italy has a rich history; its art changed the whole of Europe.",
           "The first law is about energy; the second is about disorder.",
           "I know the basics; ask me anything about it."])
]

/// One sentence, read: where the words are, and the quiet at its mark.
private struct PauseRow {
    let mark: String
    let text: String
    let leadMs: Double
    let tailMs: Double
    let markMs: Double?
    let longestMs: Double
    let markSpan: (start: Double, end: Double)?
}

func runKokoroPauses(_ arguments: [String]) async {
    let weights = arguments.first { $0.hasPrefix("--kokoro-weights=") }
        .map { KokoroWeights(directory: URL(fileURLWithPath: String($0.dropFirst("--kokoro-weights=".count)))) }
        ?? .inApplicationSupport()
    let directory = weights.directory
    let model = directory.appending(path: "kokoro-\(weights.precision.rawValue).safetensors")
    let voiceFile = directory.appending(path: "af_heart.safetensors")
    print("\n⏸  KOKORO-PAUSES (5d piece 2, F-33 A) — whole sentences, one mark each, quiet below 0.001")
    print("    model: \(model.path(percentEncoded: false))")
    guard FileManager.default.fileExists(atPath: model.path(percentEncoded: false)),
          let style = try? MLX.loadArrays(url: voiceFile).values.first else {
        print("the Kokoro weights are not on this Mac — run `bakeoff voice-kokoro` once to fetch and cast them")
        exit(1)
    }
    MLX.Memory.cacheLimit = 20 * 1024 * 1024
    let engine = KokoroTTS(modelPath: model, g2p: .misaki)
    let rate = Double(KokoroTTS.Constants.samplingRate)
    var rows: [PauseRow] = []
    for (mark, texts) in pauseSentences {
        for text in texts {
            do {
                let (samples, tokens) = try engine.generateAudio(voice: style, language: .enUS, text: text)
                let span = tokens?.first { $0.text == mark }
                    .flatMap { token in token.start_ts.flatMap { start in token.end_ts.map { (start, $0) } } }
                rows.append(readPause(samples, rate: rate, mark: mark, text: text, markSpan: span))
            } catch {
                print("  \(mark) \"\(text)\" — FAILED: \(error)")
            }
            MLX.Memory.clearCache()
        }
    }
    printKokoroPauses(rows)
    exit(0)
}

/// The quiet stretches of one utterance, at the meter's level.
private func readPause(_ samples: [Float], rate: Double, mark: String, text: String,
                       markSpan: (Double, Double)?) -> PauseRow {
    let level: Float = 0.001
    let ms = { (frames: Int) in Double(frames) / rate * 1000 }
    guard let first = samples.firstIndex(where: { abs($0) >= level }),
          let last = samples.lastIndex(where: { abs($0) >= level }) else {
        return PauseRow(mark: mark, text: text, leadMs: ms(samples.count), tailMs: 0,
                        markMs: nil, longestMs: 0, markSpan: markSpan)
    }
    var runs: [(start: Int, length: Int)] = []
    var start: Int?
    for index in first...last {
        if abs(samples[index]) < level {
            if start == nil { start = index }
        } else if let open = start {
            runs.append((open, index - open))
            start = nil
        }
    }
    let longest = runs.map(\.length).max() ?? 0
    // The run nearest the mark's predicted span (centre to centre).
    let atMark = markSpan.flatMap { span -> Int? in
        let centre = (span.0 + span.1) / 2 * rate
        let distance = { (run: (start: Int, length: Int)) in abs(Double(run.start + run.length / 2) - centre) }
        return runs.min { distance($0) < distance($1) }?.length
    }
    return PauseRow(mark: mark, text: text, leadMs: ms(first), tailMs: ms(samples.count - 1 - last),
                    markMs: atMark.map(ms), longestMs: ms(longest), markSpan: markSpan)
}

private func printKokoroPauses(_ rows: [PauseRow]) {
    print("\n| mark | sentence | lead quiet ms | quiet at the mark ms | longest quiet inside ms"
          + " | mark's predicted span ms | tail quiet ms |")
    print("|---|---|---:|---:|---:|---|---:|")
    for row in rows {
        let span = row.markSpan.map { String(format: "%.0f–%.0f", $0.start * 1000, $0.end * 1000) } ?? "—"
        let atMark = row.markMs.map { String(format: "%.0f", $0) } ?? "—"
        print(String(format: "| %@ | %@ | %.0f | %@ | %.0f | %@ | %.0f |",
                     row.mark as NSString, row.text as NSString, row.leadMs, atMark as NSString,
                     row.longestMs, span as NSString, row.tailMs))
    }
    print("\nper mark — the quiet at the mark, median (min – max):")
    for (mark, _) in pauseSentences {
        let values = rows.filter { $0.mark == mark }.compactMap(\.markMs).sorted()
        guard !values.isEmpty else { print("  \(mark)  —"); continue }
        print(String(format: "  %@  %4.0f ms  (%.0f – %.0f), %d sentences",
                     mark as NSString, median(values), values[0], values[values.count - 1], values.count))
    }
    print(String(format: "every utterance: lead quiet median %.0f ms, tail quiet median %.0f ms",
                 median(rows.map(\.leadMs).sorted()), median(rows.map(\.tailMs).sorted())))
}

/// The middle of a sorted, non-empty list — the mean of the two middles
/// when the count is even.
private func median(_ sorted: [Double]) -> Double {
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}
