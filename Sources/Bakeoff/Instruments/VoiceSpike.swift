// The `voice-spike` instrument: the two mouths at the seam they both
// implement, timed to first audio and to silence.
import Foundation
import MultiModalKit
import MultiModalKitTTS

// `swift run bakeoff voice-spike` — AC-102's gates, measured before any
// adoption ruling (D-045, the D-023 discipline). Two mouths, the same
// sentences, at the SEAM both implement, so the numbers are comparable
// by construction rather than by argument.
@MainActor
func runVoiceSpike(_ arguments: [String]) async {
    let sentences = [
        "How is the weather today?",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
        "Should I take a jacket?"
    ]

    // Flags, so the SAME instrument can measure the before and the after
    // (AC-106) instead of two instruments being compared to each other.
    // `--stepped` reproduces the pre-D-047 baseline; the default is now
    // the library's, which is `.fused`.
    let forceStepped = arguments.contains("--stepped")
    let leadMS = arguments.first(where: { $0.hasPrefix("--lead=") })
        .flatMap { Int($0.dropFirst("--lead=".count)) }
    // `nil`, NOT a constant. An explicit lead defeats the decoder-aware
    // derivation, and this line used to pass `NeuralVoice.defaultLead` —
    // `.fused`'s zero — so `--stepped` was measured with no cushion at all.
    // Every `--stepped` number this tool produced before 2026-08-23 was
    // taken that way.
    let voice = NeuralVoice(
        lead: leadMS.map { Duration.milliseconds($0) },
        multiCodeDecoderMode: forceStepped ? .stepped : .fused)
    guard await voice.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    await voiceSpikeTable(voice: voice, sentences: sentences,
                          forceStepped: forceStepped, leadMS: leadMS)
    exit(0)
}

@MainActor
private func voiceSpikeTable(voice: NeuralVoice, sentences: [String],
                             forceStepped: Bool, leadMS: Int?) async {
    print("\n🎚  VOICE SPIKE (AC-102) — the numbers the adoption ruling needs")
    // The voice's OWN lead, never a recomputation of what it should be:
    // an instrument that reports a number it did not read cannot notice
    // when the two disagree, which is the whole story of this bug.
    print("    decoder: \(forceStepped ? ".stepped" : ".fused") · lead: \(voice.lead)"
        + (leadMS == nil ? " (derived)" : " (--lead)"))
    print("    warm-up excluded, same rule as BAKEOFF.md: the first load compiles graphs")
    _ = try? await measure(voice, "Warming up the neural pipeline.")   // excluded

    print("\n| sentence | mouth | first audio | total | ")
    print("|---|---|---|---|")
    var neuralFirst: [Double] = []
    var appleFirst: [Double] = []
    for text in sentences {
        let short = text.count > 34 ? String(text.prefix(34)) + "…" : text
        if let neural = try? await measure(voice, text) {
            neuralFirst.append(neural.firstAudio)
            print(String(format: "| %@ | neural | **%.0f ms** | %.0f ms |", short, neural.firstAudio, neural.total))
        }
        if let apple = try? await measure(AppleSpeechSynthesizer(), text) {
            appleFirst.append(apple.firstAudio)
            print(String(format: "| %@ | Apple | **%.0f ms** | %.0f ms |", short, apple.firstAudio, apple.total))
        }
    }
    func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    print(String(format: "\nfirst-audio mean — neural %.0f ms · Apple %.0f ms · ratio %.1fx",
                 mean(neuralFirst), mean(appleFirst),
                 mean(appleFirst) > 0 ? mean(neuralFirst) / mean(appleFirst) : 0))
    print("\nNOT measured here, and not claimed: STOP latency (request → the room")
    print("actually quiet). The seam reports its own bookkeeping instantly; proving")
    print("silence needs the microphone probe, on the device. Thermal likewise.")
}
