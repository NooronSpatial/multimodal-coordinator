// The bake-off runner (D-025, AC-42): the same recorded speech through every
// engine that has its model, measured and printed as a markdown table.
//
//   swift run bakeoff [wav-file] [reference-txt]
//
// Defaults to the committed fixtures. Engines without a model are skipped
// with an honest line, never silently.
import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitTesting
import MultiModalKitTTS
import MultiModalKitWhisper

setbuf(stdout, nil)

let arguments = CommandLine.arguments

// `swift run bakeoff voice-spike` — AC-102's gates, measured before any
// adoption ruling (D-045, the D-023 discipline). Two mouths, the same
// sentences, at the SEAM both implement, so the numbers are comparable
// by construction rather than by argument.
if arguments.count > 1, arguments[1] == "voice-spike" {
    let sentences = [
        "How is the weather today?",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
        "Should I take a jacket?",
    ]

    /// Drives one reply through a mouth and times the two moments that
    /// matter: when sound STARTS, and when the room goes quiet.
    func measure(_ mouth: any SpeechSynthesizing, _ text: String) async throws
        -> (firstAudio: Double, total: Double)
    {
        let run = try await mouth.openUtterance()
        let clock = ContinuousClock()
        let t0 = clock.now
        var firstAudio: Duration?

        // THE READER RUNS FIRST, AND THAT IS A CORRECTION.
        //
        // The first version of this function fed the whole sentence,
        // closed it, and only THEN read the update stream. That is fair
        // to Apple, whose `feed` hands the text to the framework and
        // returns at once — and deeply unfair to the neural mouth, whose
        // `feed` does not return until the decode is finished. Its
        // `.started` was sent on time and sat buffered in the stream;
        // this function stamped it when it finally READ it. The result
        // was a first-audio number that was really a total, and a 202x
        // ratio that measured a mistake.
        //
        // The tell was in the table: neural first-audio within ~100 ms
        // of neural total, on every single row. A step trace settled it
        // — audio steps arrive every ~80 ms from the start.
        //
        // So: this task parks on the stream, and the FEEDING moves to a
        // child. The gate below is why there is no sleep here — the
        // feeder waits for a fact, not for a guess (the determinism rule).
        let gate = AsyncStream<Void>.makeStream()
        let feeder = Task {
            for await _ in gate.stream { break }
            await run.feed(text)
            await run.finishTokens()
        }
        gate.continuation.finish()      // opens the gate: the feeder may go
        for await update in run.updates {
            switch update {
            case .started: if firstAudio == nil { firstAudio = t0.duration(to: clock.now) }
            case .failed(let why): print("   ⚠️  \(why)")
            case .finished: break
            }
        }
        let total = t0.duration(to: clock.now)
        await feeder.value
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
        }
        return (firstAudio.map(ms) ?? -1, ms(total))
    }

    let voice = NeuralVoice()
    guard await voice.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    print("\n🎚  VOICE SPIKE (AC-102) — the numbers the adoption ruling needs")
    print("    warm-up excluded, same rule as BAKEOFF.md: the first load compiles graphs")
    _ = try? await measure(voice, "Warming up the neural pipeline.")   // excluded

    print("\n| sentence | mouth | first audio | total | ")
    print("|---|---|---|---|")
    var neuralFirst: [Double] = []
    var appleFirst: [Double] = []
    for text in sentences {
        let short = text.count > 34 ? String(text.prefix(34)) + "…" : text
        if let n = try? await measure(voice, text) {
            neuralFirst.append(n.firstAudio)
            print(String(format: "| %@ | neural | **%.0f ms** | %.0f ms |", short, n.firstAudio, n.total))
        }
        if let a = try? await measure(AppleSpeechSynthesizer(), text) {
            appleFirst.append(a.firstAudio)
            print(String(format: "| %@ | Apple | **%.0f ms** | %.0f ms |", short, a.firstAudio, a.total))
        }
    }
    func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    print(String(format: "\nfirst-audio mean — neural %.0f ms · Apple %.0f ms · ratio %.1fx",
                 mean(neuralFirst), mean(appleFirst),
                 mean(appleFirst) > 0 ? mean(neuralFirst) / mean(appleFirst) : 0))
    print("\nNOT measured here, and not claimed: STOP latency (request → the room")
    print("actually quiet). The seam reports its own bookkeeping instantly; proving")
    print("silence needs the microphone probe, on the device. Thermal likewise.")
    exit(0)
}

// `swift run bakeoff voice-install` — fetch the neural voice's model.
// It lives here rather than in a throwaway script because this is where
// the VOICE bake-off will run (AC-103), and the same tool should be able
// to put its subject on disk.
if arguments.count > 1, arguments[1] == "voice-install" {
    let voice = NeuralVoice()
    if await voice.modelInstalled() {
        print("✅ the neural voice's model is already on disk — nothing to fetch")
        exit(0)
    }
    print("⏬ fetching the Qwen3 neural voice (\(voice.variant.description))…")
    print("   TTSKit logs its own progress; a silent minute is not a hang.")
    do {
        _ = try await voice.ensureModel()
        let installed = await voice.modelInstalled()
        print(installed
            ? "✅ installed, and the disk check agrees"
            : "⚠️  the load succeeded but the disk check says NOT installed — "
              + "the folder this project expects is not the one TTSKit used")
        exit(installed ? 0 : 2)
    } catch {
        print("⚠️  download failed: \(error)")
        exit(1)
    }
}
let wavPath = arguments.count > 1 ? arguments[1] : "Fixtures/ryad-en.wav"
let referencePath = arguments.count > 2 ? arguments[2] : "Fixtures/bakeoff-reference.txt"

guard let reference = try? String(contentsOfFile: referencePath, encoding: .utf8) else {
    print("cannot read reference: \(referencePath)"); exit(1)
}

// One harness for CLI and app: same chunking, same settle, same scoring.
let loaded: (samples: [Float], sampleRate: Double)
do { loaded = try BakeoffHarness.loadAudio(URL(fileURLWithPath: wavPath)) }
catch { print("cannot read wav: \(wavPath) — \(error)"); exit(1) }
let samples = loaded.samples
let sampleRate = loaded.sampleRate
let seconds = Double(samples.count) / sampleRate
print("audio: \(wavPath) — \(String(format: "%.1f", seconds)) s at \(Int(sampleRate)) Hz")
print("reference: \(WordErrorRate.normalize(reference).count) words\n")

func run(_ engine: any TranscriptionEngine, label: String) async throws -> BakeoffMeasurement {
    try await BakeoffHarness.measure(engine: engine, label: label,
                                     samples: samples, sampleRate: sampleRate,
                                     reference: reference)
}

var measurements: [BakeoffMeasurement] = []

// — Apple —
let apple = AppleSpeechEngine()
if await apple.modelInstalled() {
    print("apple: warm-up run (excluded from the numbers)…")
    _ = try? await run(apple, label: "warmup")
    print("apple: measured run…")
    do { measurements.append(try await run(apple, label: "Apple SpeechAnalyzer (en_US)")) }
    catch { print("apple: failed — \(error)") }
} else {
    print("apple: model not installed on this machine — skipped (runs on iPhone, or when the asset daemon heals)")
}

// — Whisper —
let whisper = WhisperEngine()
if await whisper.modelInstalled() {
    print("whisper: warm-up run (excluded — CoreML graph compilation)…")
    _ = try? await run(whisper, label: "warmup")
    print("whisper: measured run…")
    do { measurements.append(try await run(whisper, label: "Whisper base (WhisperKit)")) }
    catch { print("whisper: failed — \(error)") }
} else {
    print("whisper: model not installed — run once with ensureModel() first")
}

guard !measurements.isEmpty else { print("\nno engine could run."); exit(1) }

print("\n| Engine | WER | sub | ins | del | decode settle |")
print("|---|---|---|---|---|---|")
for m in measurements {
    print(String(format: "| %@ | **%.1f%%** | %d | %d | %d | %.2f s |",
                 m.engineName, m.score.wer * 100, m.score.substitutions,
                 m.score.insertions, m.score.deletions, m.decodeSeconds))
}
print("")
for m in measurements {
    print("— \(m.engineName) heard:\n\(m.text)\n")
}
