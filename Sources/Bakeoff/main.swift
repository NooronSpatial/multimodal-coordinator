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
import MultiModalKitWhisper

setbuf(stdout, nil)

let arguments = CommandLine.arguments
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
