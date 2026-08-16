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
import MultiModalKitWhisper

setbuf(stdout, nil)

let arguments = CommandLine.arguments

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

    // Flags, so the SAME instrument can measure the before and the after
    // (AC-106) instead of two instruments being compared to each other.
    // `--stepped` reproduces the pre-D-047 baseline; the default is now
    // the library's, which is `.fused`.
    let forceStepped = arguments.contains("--stepped")
    let leadMS = arguments.first(where: { $0.hasPrefix("--lead=") })
        .flatMap { Int($0.dropFirst("--lead=".count)) }
    let voice = NeuralVoice(
        lead: leadMS.map { Duration.milliseconds($0) } ?? NeuralVoice.defaultLead,
        multiCodeDecoderMode: forceStepped ? .stepped : .fused)
    guard await voice.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    print("\n🎚  VOICE SPIKE (AC-102) — the numbers the adoption ruling needs")
    print("    decoder: \(forceStepped ? ".stepped" : ".fused") · lead: \(leadMS.map { "\($0) ms" } ?? "default (\(NeuralVoice.defaultLead))")")
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

/// A tiny seeded generator, so the blind order is REPRODUCIBLE. The seed
/// is printed with the result: a listening test nobody can re-run is an
/// anecdote, and this repo does not record anecdotes as data.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// CAPTURING WHAT THE MOUTH ACTUALLY SAYS (AC-103, the objective half).
///
/// A tap on the engine's mixer, which is deliberately the LAST point
/// before the speaker: it catches the audio including our own rendering,
/// resampling and buffering, which is what a listener would really hear.
/// Capturing the model's raw 24 kHz PCM instead would flatter us by
/// measuring the decoder rather than the pipeline.
///
/// `@unchecked Sendable` with the usual proof: one `Mutex` owns every
/// mutable byte, the tap closure only appends under it, and nothing
/// suspends while it is held.
final class MixerCapture: @unchecked Sendable {
    private let collected = Mutex<(samples: [Float], rate: Double)>(([], 0))
    private let engine: AVAudioEngine

    /// THE ENGINE IS NOT STARTED HERE, and that is the whole lesson of
    /// this type. The first version called `prepare()` and `start()` in
    /// this initialiser, before any player node existed. An engine
    /// started with no source node never pulls, so the player attached
    /// afterwards never rendered — and because the buffers are now
    /// scheduled with `.dataPlayedBack`, their completions correctly
    /// never fired and the whole tool hung at 0% CPU.
    ///
    /// The old `.dataConsumed` callback would have reported those
    /// buffers "done" and produced a table of silence. The hang was the
    /// honest failure of a more honest callback.
    ///
    /// So: `NeuralVoiceRun` starts the engine, with its player already
    /// attached, and the tap goes on afterwards.
    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// The capture's true rate, learned from the first buffer rather
    /// than asked of a node that may not be configured yet.
    var sampleRate: Double { collected.withLock { $0.rate } }

    func record() {
        collected.withLock { $0 = ([], 0) }
        // `self`, not the Mutex: a Mutex is non-copyable, so a capture
        // list would try to consume it out of the object that owns it.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [self] buffer, _ in
            guard let channel = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            // Channel 0 only: the source is mono, so the mixer's second
            // channel is a copy and averaging would buy nothing.
            let slice = Array(UnsafeBufferPointer(start: channel[0], count: frames))
            collected.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = buffer.format.sampleRate
            }
        }
    }

    func stop() -> [Float] {
        engine.mainMixerNode.removeTap(onBus: 0)
        return collected.withLock { $0.samples }
    }
}

/// Apple's mouth does NOT render through our engine, so the tap cannot
/// see it. `write` is the framework's own offline path — same synthesis,
/// no speaker. Stated as a caveat wherever its numbers appear: it is not
/// the identical code path we ship, though it is the identical voice.
func captureApple(_ text: String) async -> (samples: [Float], sampleRate: Double)? {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    // One lock over everything mutable, `resumed` included: the callback
    // arrives on the framework's thread, and a plain `var` flag read and
    // written from there is a race that would eventually resume a
    // continuation twice — which traps.
    let box = Mutex<(samples: [Float], rate: Double, resumed: Bool)>(([], 0, false))

    let result: (samples: [Float], sampleRate: Double)? = await withCheckedContinuation {
        continuation in
        synthesizer.write(utterance) { buffer in
            // `synthesizer` is touched HERE ON PURPOSE. Nothing else
            // retains it once this function's frame is gone, and a
            // deallocated synthesizer simply never calls back — the
            // continuation then waits forever. That is precisely how
            // this tool hung the first time it ran, at 0% CPU on
            // sentence 1, and `withExtendedLifetime` below is the belt
            // to this closure's braces.
            _ = synthesizer
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                let finished: (samples: [Float], sampleRate: Double)?? = box.withLock {
                    guard !$0.resumed else { return .none }
                    $0.resumed = true
                    return .some($0.samples.isEmpty ? nil : ($0.samples, $0.rate))
                }
                if let finished { continuation.resume(returning: finished) }
                return
            }
            guard let channel = pcm.floatChannelData else { return }
            let slice = Array(UnsafeBufferPointer(start: channel[0],
                                                  count: Int(pcm.frameLength)))
            box.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = pcm.format.sampleRate
            }
        }
    }
    withExtendedLifetime(synthesizer) {}
    return result
}

// `swift run bakeoff voice-wer` — AC-103's OBJECTIVE half, and the
// instrument the fused/stepped question actually needs.
//
// speak → capture → transcribe → WER against the text we asked for.
// Intelligibility as a NUMBER, using the two transcription engines this
// repo already owns, which is the whole point: a pipeline that can
// listen can grade its own mouth.
//
// WHY SEVERAL DRAWS PER SENTENCE. §11 and §13 both recorded it: this
// model is non-deterministic in LENGTH — 8240 ms of audio for a sentence
// one run, 6480 ms the next — and the seed did not fix it. One draw per
// mouth would compare draws, not mouths. Averaging over draws is what
// makes the comparison about the decoder.
if arguments.count > 1, arguments[1] == "voice-wer" {
    let sentences = [
        "How is the weather today?",
        "I can hear you. Say that again and I will stop talking.",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
    ]
    let draws = 3
    let lead = Duration.milliseconds(800)

    // ONE ENGINE PER VOICE, and that is a correction. Sharing a single
    // engine put every fused utterance immediately after a stepped
    // teardown detaching a node from the same graph — and the three
    // empty captures in the first run were all fused, all following a
    // stepped draw. Whether or not that race is the cause, a measurement
    // cannot be allowed to depend on it.
    let steppedEngine = AVAudioEngine()
    let fusedEngine = AVAudioEngine()
    let steppedCapture = MixerCapture(engine: steppedEngine)
    let fusedCapture = MixerCapture(engine: fusedEngine)

    // The seam's plain implementation (AC-108). The tool still needs the
    // engine itself, because it taps the mixer — but the voice only ever
    // sees a host, so the start-order rule that hung this tool now lives
    // in one place instead of here.
    let stepped = NeuralVoice(renderingOn: AudioEnginePlaybackHost(engine: steppedEngine),
                              lead: lead, multiCodeDecoderMode: .stepped)
    let fused = NeuralVoice(renderingOn: AudioEnginePlaybackHost(engine: fusedEngine),
                            lead: lead, multiCodeDecoderMode: .fused)
    guard await stepped.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    let whisper = WhisperEngine()
    guard await whisper.modelInstalled() else {
        print("whisper's model is not installed — the grader is missing, so nothing is graded")
        exit(1)
    }

    print("\n📝  ROUND-TRIP WER (AC-103, the objective half)")
    print("    speak → capture at the mixer → transcribe → WER")
    print("    \(draws) draws per neural mouth per sentence, because the voice")
    print("    is non-deterministic in length (INSTRUMENTS §11, §13).\n")

    print("    loading…")
    do { try await stepped.ensureModel(); try await fused.ensureModel() }
    catch { print("load failed: \(error)"); exit(1) }
    _ = try? await measure(stepped, "Warming up.")
    _ = try? await measure(fused, "Warming up.")
    _ = try? await BakeoffHarness.measure(engine: whisper, label: "warmup",
                                          samples: [Float](repeating: 0, count: 16000),
                                          sampleRate: 16000, reference: "warm up")

    struct Row { let mouth: String; let sentence: Int; let draw: Int
                 let wer: Double; let heard: String }
    var rows: [Row] = []

    func grade(_ mouth: String, _ sentenceIndex: Int, _ draw: Int,
               _ samples: [Float], _ rate: Double, _ reference: String) async {
        // WHAT WAS ACTUALLY CAPTURED. An empty transcript can mean the
        // voice was unintelligible or that the tap caught nothing, and
        // those two lead to opposite conclusions. Length and peak
        // amplitude separate them on sight, so they are always printed.
        let peak = samples.map { abs($0) }.max() ?? 0
        let seconds = rate > 0 ? Double(samples.count) / rate : 0
        guard !samples.isEmpty, peak > 0.001 else {
            print(String(format: "      %@: captured %.2f s, peak %.4f — SILENT, not graded",
                         mouth, seconds, peak))
            return
        }
        do {
            let m = try await BakeoffHarness.measure(
                engine: whisper, label: mouth,
                samples: samples, sampleRate: rate, reference: reference)
            rows.append(Row(mouth: mouth, sentence: sentenceIndex, draw: draw,
                            wer: m.score.wer, heard: m.text))
            print(String(format: "      %-8@ draw %d — WER %.3f — %.2f s, peak %.3f — \"%@\"",
                         mouth as NSString, draw, m.score.wer, seconds, peak,
                         m.text as NSString))
        } catch {
            print("      \(mouth): transcription failed — \(error)")
        }
    }

    for (index, text) in sentences.enumerated() {
        print("\n  sentence \(index + 1): \"\(text)\"")

        // Apple's mouth, once: it is deterministic, so extra draws would
        // measure nothing. Captured through `write` rather than the tap,
        // because it does not render through our engine — same voice,
        // not the identical code path we ship.
        if let appleAudio = await captureApple(text) {
            await grade("apple", index, 1, appleAudio.samples, appleAudio.sampleRate, text)
        } else {
            print("      apple: write produced nothing — not graded")
        }

        for draw in 1...draws {
            steppedCapture.record()
            _ = try? await measure(stepped, text)
            let steppedAudio = steppedCapture.stop()
            await grade("stepped", index, draw, steppedAudio,
                        steppedCapture.sampleRate, text)

            fusedCapture.record()
            _ = try? await measure(fused, text)
            let fusedAudio = fusedCapture.stop()
            await grade("fused", index, draw, fusedAudio,
                        fusedCapture.sampleRate, text)
        }
    }

    print("\n════════════════════════════════════════════════")
    print("| mouth | draws graded | mean WER | worst |")
    print("|---|---|---|---|")
    for mouth in ["apple", "stepped", "fused"] {
        let mine = rows.filter { $0.mouth == mouth }
        guard !mine.isEmpty else { print("| \(mouth) | 0 | — | — |"); continue }
        let mean = mine.map(\.wer).reduce(0, +) / Double(mine.count)
        let worst = mine.map(\.wer).max() ?? 0
        print(String(format: "| %@ | %d | **%.3f** | %.3f |",
                     mouth, mine.count, mean, worst))
    }
    print("\n0.000 is perfect. WER can exceed 1.0 when the voice rambles")
    print("and the transcriber hears words that were never asked for.")
    exit(0)
}

// `swift run bakeoff voice-levers` — AC-106, D-046 = B. Every decode
// lever that survived adversarial verification, measured SERIALLY on one
// machine, because two models decoding at once would corrupt both
// timings. The numbers land on stderr beside each config banner.
if arguments.count > 1, arguments[1] == "voice-levers" {
    // ONE long single-chunk sentence. Long, so the fixed prefill is
    // amortised and STEADY rtf is what moves; single-chunk, so the
    // sequential/batch branch is not part of what is being compared.
    let sentence = "The audio travels through a ring buffer into a pump "
        + "that cuts it into small chunks."
    let runsPerConfig = 3

    struct Lever {
        let name: String
        let multi: Qwen3MultiCodeDecoderMode
        let speech: Qwen3SpeechDecoderMode
        let temperature: Float?
    }
    let levers = [
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
              speech: .latencyOptimized, temperature: 0),
    ]

    func banner(_ text: String) {
        FileHandle.standardError.write(Data("\n=== \(text) ===\n".utf8))
    }

    print("\n🔧 VOICE LEVERS (AC-106) — serial, release, one machine")
    print("    watch STEADY, not RTF: the whole-run factor still carries prefill")

    for lever in levers {
        banner(lever.name)
        // A seed makes the draws comparable across configs. `.fused`
        // samples in-graph, so it is NOT expected to match `.stepped`
        // sample-for-sample even seeded — the seed removes run-to-run
        // noise WITHIN a config, which is what a median needs.
        let voice = NeuralVoice(lead: .zero,
                                multiCodeDecoderMode: lever.multi,
                                speechDecoderMode: lever.speech,
                                temperature: lever.temperature,
                                seed: 20260816)
        do {
            try await voice.ensureModel()
        } catch {
            print("| \(lever.name) | LOAD FAILED — \(error) |")
            FileHandle.standardError.write(Data("   load failed: \(error)\n".utf8))
            continue
        }
        // Warm-up, excluded: the first decode after a load compiles and
        // warms graphs, the same rule voice-spike follows.
        _ = try? await measure(voice, "Warming up.")
        for run in 1...runsPerConfig {
            FileHandle.standardError.write(Data("  run \(run):\n".utf8))
            _ = try? await measure(voice, sentence)
        }
    }
    print("\nRead the STEADY column from stderr, median of \(runsPerConfig) per config.")
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
