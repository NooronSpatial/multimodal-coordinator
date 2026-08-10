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

// Load the whole WAV as Float samples in its native rate.
let file: AVAudioFile
do { file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath)) }
catch { print("cannot read wav: \(wavPath) — \(error)"); exit(1) }
let format = file.processingFormat
let frameCount = AVAudioFrameCount(file.length)
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      (try? file.read(into: buffer)) != nil,
      let channel = buffer.floatChannelData else {
    print("cannot decode wav"); exit(1)
}
let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
let sampleRate = format.sampleRate
let seconds = Double(samples.count) / sampleRate
print("audio: \(wavPath) — \(String(format: "%.1f", seconds)) s at \(Int(sampleRate)) Hz")
print("reference: \(WordErrorRate.normalize(reference).count) words\n")

struct Measurement {
    let engineName: String
    let text: String
    let score: WordErrorRate.Score
    let decodeSeconds: Double
}

/// Feeds the whole file through ONE run of the engine, 20 ms at a time,
/// then settles and waits for the final. Returns text + decode latency
/// (finishAudio → final wall-clock — the settle cost a user would feel).
func run(_ engine: any TranscriptionEngine, label: String) async throws -> Measurement {
    let run = try await engine.openRun(
        format: AudioStreamFormat(sampleRate: sampleRate, channels: 1))
    let chunkFrames = Int(sampleRate * 0.02)
    var offset = 0
    while offset < samples.count {
        let end = min(offset + chunkFrames, samples.count)
        let chunk = MultiModalKit.AudioChunk(
            samples: Array(samples[offset..<end]),
            start: AudioTime(frames: offset, sampleRate: sampleRate))
        await run.feed(chunk)
        offset = end
    }
    let settleStart = Date()
    await run.finishAudio()
    var text = ""
    for await update in run.updates {
        switch update {
        case .partial(let partial): text = partial
        case .final(let final): text = final
        case .failed(let failure): throw failure
        }
    }
    let decodeSeconds = Date().timeIntervalSince(settleStart)
    return Measurement(engineName: label, text: text,
                       score: WordErrorRate.score(reference: reference, hypothesis: text),
                       decodeSeconds: decodeSeconds)
}

var measurements: [Measurement] = []

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
