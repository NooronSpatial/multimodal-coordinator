// The `voice-levers` instrument: every decode lever that survived
// adversarial verification, measured serially on one machine.
import Foundation
import MultiModalKitTTS
import TTSKit

// `swift run bakeoff voice-levers` — AC-106, D-046 = B. Every decode
// lever that survived adversarial verification, measured SERIALLY on one
// machine, because two models decoding at once would corrupt both
// timings. The numbers land on stderr beside each config banner.
@MainActor
func runVoiceLevers(_ arguments: [String]) async throws {
    // ONE long single-chunk sentence. Long, so the fixed prefill is
    // amortised and STEADY rtf is what moves; single-chunk, so the
    // sequential/batch branch is not part of what is being compared.
    let sentence = "The audio travels through a ring buffer into a pump "
        + "that cuts it into small chunks."
    let runsPerConfig = 3

    // WHICH MODEL SPEAKS, parsed by the library's one parser (D-072 F-3,
    // AC-163): `--voice-model=1.7b` runs the whole sweep on the big model
    // so its rows land beside 0.6B's from the same stopwatch. A value the
    // project cannot honor refuses here, never a silent 0.6B.
    let sweepModel: TTSModelVariant
    do {
        sweepModel = try VoiceLevers.parsed(fromArguments: arguments).model
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("bakeoff: \(refusal.message)\n".utf8))
        exit(2)
    }

    let levers = leverSweep()

    let sweepModelName = sweepModel == .qwen3TTS_1_7b ? "1.7B" : "0.6B"
    print("\n🔧 VOICE LEVERS (AC-106) — serial, release, one machine · model \(sweepModelName)")
    print("    watch STEADY, not RTF: the whole-run factor still carries prefill")

    for lever in levers {
        await runLever(lever, model: sweepModel, sentence: sentence,
                       runsPerConfig: runsPerConfig)
    }
    print("\nSTEADY is the column that compares: totals scale with how much"
        + " audio a model made, \(runsPerConfig) runs per config, take the median.")
    exit(0)
}

/// One configuration in the sweep: the decoder pair it selects, and the
/// temperature it pins.
private struct Lever {
    let name: String
    let multi: Qwen3MultiCodeDecoderMode
    let speech: Qwen3SpeechDecoderMode
    let temperature: Float?
}

@MainActor
private func leverSweep() -> [Lever] {
    [
        Lever(name: "baseline (stepped + latency)", multi: .stepped,
              speech: .latencyOptimized, temperature: nil),
        Lever(name: "rank 2: fused", multi: .fused,
              speech: .latencyOptimized, temperature: nil),
        Lever(name: "rank 3: throughputOptimized", multi: .stepped,
              speech: .throughputOptimized, temperature: nil),
        Lever(name: "rank 4: fused + throughputOptimized", multi: .fused,
              speech: .throughputOptimized, temperature: nil),
        Lever(name: "rank 5: temperature 0 (on stepped)", multi: .stepped,
              speech: .latencyOptimized, temperature: 0),
        Lever(name: "rank 5b: temperature 0 (on fused)", multi: .fused,
              speech: .latencyOptimized, temperature: 0)
    ]
}

@MainActor
private func banner(_ text: String) {
    FileHandle.standardError.write(Data("\n=== \(text) ===\n".utf8))
}

@MainActor
private func runLever(_ lever: Lever, model: TTSModelVariant, sentence: String,
                      runsPerConfig: Int) async {
    banner(lever.name)
    // A seed makes the draws comparable across configs. `.fused`
    // samples in-graph, so it is NOT expected to match `.stepped`
    // sample-for-sample even seeded — the seed removes run-to-run
    // noise WITHIN a config, which is what a median needs.
    let voice = NeuralVoice(variant: model,
                            lead: .zero,
                            multiCodeDecoderMode: lever.multi,
                            speechDecoderMode: lever.speech,
                            temperature: lever.temperature,
                            seed: 20260816)
    do {
        try await voice.ensureModel()
    } catch {
        print("| \(lever.name) | LOAD FAILED — \(error) |")
        FileHandle.standardError.write(Data("   load failed: \(error)\n".utf8))
        return
    }
    // THE STEADY NUMBERS, FROM OUR OWN INSTRUMENT (AC-163).
    //
    // This footer told the reader to "read the STEADY column from
    // stderr" — and there is no such column: it depended on the
    // VENDOR's logging, which prints nothing here today. The 4l run
    // caught it the way §30's rule predicts: the instruction pointed
    // at a number the instrument could not produce, so the sweep's
    // headline totals were the only thing to read — and totals are
    // NOT comparable across models, because a model that says the
    // same sentence in less audio finishes sooner for a reason that
    // has nothing to do with speed.
    //
    // `DecodeMargin` is ours, it is what the phone already logs, and
    // it carries the audio length that makes the ratio meaningful.
    let margins = MarginBox()
    await voice.reportMargins { margin in margins.record(margin) }
    // Warm-up, excluded: the first decode after a load compiles and
    // warms graphs, the same rule voice-spike follows.
    _ = try? await measure(voice, "Warming up.")
    margins.reset()
    // MEASURED AND PRINTED, not swallowed. This loop used to be
    // `_ = try? await measure(...)`: the result discarded, the error
    // dropped, and the numbers left entirely to TTSKit's own logging.
    // A run that FAILED printed "run 1:" and nothing — identical to a
    // run that succeeded quietly. A whole levers sweep came back with
    // six empty configs and no way to tell whether that meant silence
    // or failure.
    await runLeverRuns(voice: voice, lever: lever, sentence: sentence,
                       runsPerConfig: runsPerConfig, margins: margins)
}

@MainActor
private func runLeverRuns(voice: NeuralVoice, lever: Lever, sentence: String,
                          runsPerConfig: Int, margins: MarginBox) async {
    for run in 1...runsPerConfig {
        do {
            let timing = try await measure(voice, sentence)
            // The margin for THIS run, or the honest absence of one.
            // A row that cannot say its audio length says so, rather
            // than borrowing the previous run's number.
            let said: String
            if let margin = margins.take() {
                said = String(format: "audio %.0f ms | steady %.3f%@",
                              margin.audioMilliseconds,
                              margin.steadyRealTimeFactor ?? margin.realTimeFactor,
                              margin.completed ? "" : " (INCOMPLETE)")
            } else {
                said = "audio — | steady — (no margin reported)"
            }
            print(String(format: "| %@ | run %d | first audio %.0f ms | total %.0f ms | %@ |",
                         lever.name, run, timing.firstAudio, timing.total, said))
        } catch {
            print("| \(lever.name) | run \(run) | DECODE FAILED — \(error) |")
        }
    }
}
