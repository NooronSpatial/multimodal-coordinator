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
import TTSKit
import Synchronization
import MultiModalKitMLX
import MultiModalKitWhisper

setbuf(stdout, nil)

let arguments = CommandLine.arguments

if arguments.count > 1, arguments[1] == "memory-fit" { await runMemoryFit(arguments) }
if arguments.count > 1, arguments[1] == "fetch" { await runFetch(arguments) }
if arguments.count > 1, arguments[1] == "ask" { await runAsk(arguments) }
if arguments.count > 1, arguments[1] == "mind-off" { await runMindOff(arguments) }
if arguments.count > 1, arguments[1] == "voice-spike" { await runVoiceSpike(arguments) }
if arguments.count > 1, arguments[1] == "voice-onmic" { try await runVoiceOnMic(arguments) }
if arguments.count > 1, arguments[1] == "voice-selfecho" { try await runVoiceSelfEcho(arguments) }
if arguments.count > 1, arguments[1] == "voice-wer" { try await runVoiceWER(arguments) }
if arguments.count > 1, arguments[1] == "voice-levers" { try await runVoiceLevers(arguments) }
if arguments.count > 1, arguments[1] == "cushion-sweep" { await runCushionSweep(arguments) }
if arguments.count > 1, arguments[1] == "voice-install" { await runVoiceInstall() }
if arguments.count > 1, arguments[1] == "voice-kokoro" { await runVoiceKokoro(arguments) }
if arguments.count > 1, arguments[1] == "graph-probe" { await runGraphProbe(arguments) }

let wavPath = arguments.count > 1 ? arguments[1] : "Fixtures/ryad-en.wav"
let referencePath = arguments.count > 2 ? arguments[2] : "Fixtures/bakeoff-reference.txt"

guard let reference = try? String(contentsOfFile: referencePath, encoding: .utf8) else {
    print("cannot read reference: \(referencePath)"); exit(1)
}

// One harness for CLI and app: same chunking, same settle, same scoring.
let loaded: (samples: [Float], sampleRate: Double)
do {
    loaded = try BakeoffHarness.loadAudio(URL(fileURLWithPath: wavPath))
} catch { print("cannot read wav: \(wavPath) — \(error)"); exit(1) }
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
// 4s: the ear ships with OS 26 and the library no longer requires it, so
// a bake-off on an older Mac has to say which half is missing. A row
// silently absent is how a bake-off starts lying (D-054).
if #available(macOS 26.0, *) {
    let apple = AppleSpeechEngine()
    if await apple.modelInstalled() {
        print("apple: warm-up run (excluded from the numbers)…")
        _ = try? await run(apple, label: "warmup")
        print("apple: measured run…")
        do {
            measurements.append(try await run(apple, label: "Apple SpeechAnalyzer (en_US)"))
        } catch { print("apple: failed — \(error)") }
    } else {
        print("apple: model not installed on this machine — skipped (runs on iPhone, or when the asset daemon heals)")
    }
} else {
    print("apple: NOT RUN — SpeechAnalyzer needs macOS 26, this Mac is older.")
}

// — Whisper —
let whisper = WhisperEngine()
if await whisper.modelInstalled() {
    print("whisper: warm-up run (excluded — CoreML graph compilation)…")
    _ = try? await run(whisper, label: "warmup")
    print("whisper: measured run…")
    do {
        measurements.append(try await run(whisper, label: "Whisper base (WhisperKit)"))
    } catch { print("whisper: failed — \(error)") }
} else {
    print("whisper: model not installed — run once with ensureModel() first")
}

guard !measurements.isEmpty else { print("\nno engine could run."); exit(1) }

print("\n| Engine | WER | sub | ins | del | decode settle |")
print("|---|---|---|---|---|---|")
for measurement in measurements {
    print(String(format: "| %@ | **%.1f%%** | %d | %d | %d | %.2f s |",
                 measurement.engineName, measurement.score.wer * 100, measurement.score.substitutions,
                 measurement.score.insertions, measurement.score.deletions, measurement.decodeSeconds))
}
print("")
for measurement in measurements {
    print("— \(measurement.engineName) heard:\n\(measurement.text)\n")
}
