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
    let fused = arguments.contains("--fused")
    let leadMS = arguments.first(where: { $0.hasPrefix("--lead=") })
        .flatMap { Int($0.dropFirst("--lead=".count)) }
    let voice = NeuralVoice(
        lead: leadMS.map { Duration.milliseconds($0) } ?? NeuralVoice.defaultLead,
        multiCodeDecoderMode: fused ? .fused : .stepped)
    guard await voice.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    print("\n🎚  VOICE SPIKE (AC-102) — the numbers the adoption ruling needs")
    print("    decoder: \(fused ? ".fused" : ".stepped") · lead: \(leadMS.map { "\($0) ms" } ?? "default")")
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

// `swift run bakeoff voice-listen` — AC-103's SUBJECTIVE half, run
// honestly. D-045 and AC-103 both say the same thing: anything
// subjective is reported as opinion and labelled as such, never dressed
// as data. This is the instrument for collecting that opinion without
// poisoning it.
//
// THE COMPARISON IS `.stepped` vs `.fused`, BLIND. Same model, same
// voice, same text, same lead — only the decoder differs, which is the
// one thing a listener cannot guess from the sound of the words. Apple
// plays first as a REFERENCE and is deliberately NOT blinded: its voice
// is recognisable in three syllables, so pretending otherwise would be
// theatre rather than blinding.
//
// Both neural clips get the SAME 800 ms lead. `.fused` does not need it
// (AC-106: it decodes ahead of the ear) but `.stepped` does, and a test
// where one candidate stutters because of OUR buffering would measure
// the buffer, not the voice.
if arguments.count > 1, arguments[1] == "voice-listen" {
    let sentences = [
        "How is the weather today?",
        "I can hear you. Say that again and I will stop talking.",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
    ]
    let seed: UInt64 = 20260816
    let lead = Duration.milliseconds(800)

    let apple = AppleSpeechSynthesizer()
    let stepped = NeuralVoice(lead: lead, multiCodeDecoderMode: .stepped, seed: seed)
    let fused = NeuralVoice(lead: lead, multiCodeDecoderMode: .fused, seed: seed)

    guard await stepped.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    print("\n🎧  LISTENING TEST (AC-103, the opinion half)")
    print("    Two neural decoders, blind, labelled A and B.")
    print("    Apple plays first each round as a reference — not blinded,")
    print("    because that voice gives itself away in three syllables.")
    print("\n    Loading both decoders (this takes a moment)…")
    do {
        try await stepped.ensureModel()
        try await fused.ensureModel()
    } catch {
        print("⚠️  load failed: \(error)")
        exit(1)
    }
    // Warm-ups, excluded and unheard-of-purpose: the first decode after a
    // load compiles graphs, and a first clip that stumbles would bias the
    // whole round against whichever mouth drew it.
    _ = try? await measure(stepped, "Warming up.")
    _ = try? await measure(fused, "Warming up.")

    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: " ")
        guard let line = readLine() else { return nil }
        return line.trimmingCharacters(in: .whitespaces).uppercased()
    }

    var rng = SeededRNG(seed: seed)
    var rounds: [(text: String, aWasFused: Bool, choice: String)] = []

    for (index, text) in sentences.enumerated() {
        let aIsFused = Bool.random(using: &rng)
        print("\n────────────────────────────────────────────────")
        print("ROUND \(index + 1) of \(sentences.count): \"\(text)\"")

        var choice: String? = nil
        while choice == nil {
            print("\n  ▶ reference (Apple)…")
            _ = try? await measure(apple, text)
            print("  ▶ clip A…")
            _ = try? await measure(aIsFused ? fused : stepped, text)
            print("  ▶ clip B…")
            _ = try? await measure(aIsFused ? stepped : fused, text)

            guard let answer = ask("\n  Which neural clip sounded better? [A / B / S same / R replay / Q quit]")
            else {
                print("\n(no input — nothing recorded)")
                exit(0)
            }
            switch answer {
            case "A", "B", "S": choice = answer
            case "Q": print("\nstopped early — \(rounds.count) round(s) recorded"); choice = "Q"
            case "R": print("  replaying…")
            default: print("  please answer A, B, S, R or Q")
            }
        }
        if choice == "Q" { break }
        rounds.append((text, aIsFused, choice!))
    }

    // THE REVEAL, only now.
    print("\n════════════════════════════════════════════════")
    print("REVEAL (seed \(seed) — re-runnable, same order)\n")
    print("| round | clip A was | clip B was | preferred |")
    print("|---|---|---|---|")
    var fusedWins = 0, steppedWins = 0, ties = 0
    for (i, r) in rounds.enumerated() {
        let aName = r.aWasFused ? "fused" : "stepped"
        let bName = r.aWasFused ? "stepped" : "fused"
        let picked: String
        switch r.choice {
        case "A": picked = aName; if r.aWasFused { fusedWins += 1 } else { steppedWins += 1 }
        case "B": picked = bName; if r.aWasFused { steppedWins += 1 } else { fusedWins += 1 }
        default:  picked = "no difference heard"; ties += 1
        }
        print("| \(i + 1) | \(aName) | \(bName) | **\(picked)** |")
    }
    print("\nfused \(fusedWins) · stepped \(steppedWins) · no difference \(ties)")
    print("\nThis is an OPINION from one listener over \(rounds.count) round(s),")
    print("and it is recorded as one. It does not measure intelligibility —")
    print("that is the round-trip WER half of AC-103, and it is a number.")
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
