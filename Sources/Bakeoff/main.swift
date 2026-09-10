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
if arguments.count > 1, arguments[1] == "determinism" { await runDeterminism(arguments) }
if arguments.count > 1, arguments[1] == "install-size" { await runInstallSize(arguments) }
if arguments.count > 1, arguments[1] == "voice-spike" { await runVoiceSpike(arguments) }
if arguments.count > 1, arguments[1] == "voice-onmic" { try await runVoiceOnMic(arguments) }
if arguments.count > 1, arguments[1] == "voice-selfecho" { try await runVoiceSelfEcho(arguments) }
if arguments.count > 1, arguments[1] == "voice-wer" { try await runVoiceWER(arguments) }
if arguments.count > 1, arguments[1] == "voice-levers" { try await runVoiceLevers(arguments) }
if arguments.count > 1, arguments[1] == "cushion-sweep" { await runCushionSweep(arguments) }
if arguments.count > 1, arguments[1] == "voice-install" { await runVoiceInstall() }
if arguments.count > 1, arguments[1] == "voice-kokoro" { await runVoiceKokoro(arguments) }
if arguments.count > 1, arguments[1] == "graph-probe" { await runGraphProbe(arguments) }

let positional = arguments.dropFirst().filter { !$0.hasPrefix("--") }
let wavPath = positional.count > 0 ? positional[positional.startIndex] : "Fixtures/ryad-en.wav"
let referencePath = positional.count > 1 ? positional[positional.startIndex + 1] : "Fixtures/bakeoff-reference.txt"

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
// 4u (AC-212): `--model=small --language=ar` — the Arabic ear is Whisper
// `small` with a hint (D-097 F-2), and the gap to `base` without one is
// measured, not assumed. Defaults are the old behaviour exactly.
let whisperModel = arguments.first { $0.hasPrefix("--model=") }.map { String($0.dropFirst(8)) } ?? "base"
let whisperLanguage = arguments.first { $0.hasPrefix("--language=") }.map { String($0.dropFirst(11)) }
let whisper = WhisperEngine(model: whisperModel, language: whisperLanguage)
// `--fetch`: put the model on disk first, through the same ModelBacked
// path the app uses — so a measurement of `small` names the command that
// produced its weights (R6) instead of a click nobody can repeat.
if arguments.contains("--fetch"), await !whisper.modelInstalled() {
    print("whisper: fetching \(whisperModel)…")
    do {
        try await whisper.ensureModel()      // ModelBacked: fetch if missing, idempotent
        print("whisper: \(whisperModel) installed: \(await whisper.modelInstalled())")
    } catch { print("whisper: fetch FAILED — \(error)") }
}
if await whisper.modelInstalled() {
    print("whisper: warm-up run (excluded — CoreML graph compilation)…")
    _ = try? await run(whisper, label: "warmup")
    print("whisper: measured run…")
    do {
        // The row says which model and which hint — a table that said
        // "base" for small would be the lying-instrument class (D-054).
        let hint = whisperLanguage.map { " +\($0)" } ?? ""
        measurements.append(try await run(whisper, label: "Whisper \(whisperModel)\(hint) (WhisperKit)"))
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
