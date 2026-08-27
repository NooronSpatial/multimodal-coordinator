// The `voice-wer` instrument: speak → capture → transcribe → WER, and the
// grader, the mouths and the table it needs to do that.
import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitTesting
import MultiModalKitTTS
import MultiModalKitWhisper
import TTSKit

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
@MainActor
func runVoiceWER(_ arguments: [String]) async throws {
    let sentences = [
        "How is the weather today?",
        "I can hear you. Say that again and I will stop talking.",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks."
    ]
    let draws = 3
    let lead = werLead(arguments)

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

    let mouths = try werMouths(arguments, lead: lead,
                           steppedEngine: steppedEngine, fusedEngine: fusedEngine)
    let stepped = mouths.stepped
    let fused = mouths.fused
    let audioDirectory = werAudioDirectory(arguments)
    guard await stepped.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    let whisper = WhisperEngine()
    guard await whisper.modelInstalled() else {
        print("whisper's model is not installed — the grader is missing, so nothing is graded")
        exit(1)
    }

    await werWarmUp(draws: draws, stepped: stepped, fused: fused, whisper: whisper)

    let grader = Grader(whisper: whisper, audioDirectory: audioDirectory)
    await werRunDraws(sentences: sentences, draws: draws,
                      bench: Bench(stepped: stepped, fused: fused,
                                   steppedCapture: steppedCapture,
                                   fusedCapture: fusedCapture, grader: grader))

    werTable(rows: grader.rows, levers: mouths.levers, lead: lead)
    exit(0)
}

@MainActor
private func werLead(_ arguments: [String]) -> Duration {
    let leadOverride: Duration? = {
        do {
            return try VoiceLevers.parsed(fromArguments: arguments).lead
        } catch { return nil }   // a bad value is reported by the parse below
    }()
    // `--lead=` is THE CONTROL for the starvation question (4l, 2026-08-27).
    // Ryad's ear caught a hitch in audio rendered on this Mac with the
    // phone's levers, and two explanations fit the same recording:
    // the bank ran dry (RTF 1.114 > 1.0 with only 800 ms banked), or the
    // throughput vocoder simply speaks in a choppier way. They are told
    // apart by ONE variable — starvation disappears when the cushion is
    // large enough, prosody does not — so the cushion had to stop being
    // a constant here. Default unchanged, so every earlier number in
    // INSTRUMENTS still describes the same run.
    return leadOverride ?? Duration.milliseconds(800)
}

/// The pair of mouths under test, and the levers that made them.
private struct Mouths {
    let levers: VoiceLevers
    let stepped: NeuralVoice
    let fused: NeuralVoice
}

@MainActor
private func werMouths(_ arguments: [String], lead: Duration,
                       steppedEngine: AVAudioEngine,
                       fusedEngine: AVAudioEngine) throws -> Mouths {
    // The seam's plain implementation (AC-108). The tool still needs the
    // engine itself, because it taps the mixer — but the voice only ever
    // sees a host, so the start-order rule that hung this tool now lives
    // in one place instead of here.
    // WHICH MODEL SPEAKS (AC-163), through the library's one parser. The
    // sweep raised a question its own numbers cannot answer: 1.7B makes
    // MUCH shorter audio for the same sentence, and "compact" and
    // "dropping words" look identical on a stopwatch. This tool is the
    // one that can tell them apart, so it must be able to run either.
    let werLevers: VoiceLevers
    do {
        werLevers = try VoiceLevers.parsed(fromArguments: arguments)
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("bakeoff: \(refusal.message)\n".utf8))
        exit(2)
    }
    let werModel = werLevers.model
    // THE VOCODER IS A LEVER HERE TOO, and that is the point of this run:
    // the phone cannot load `.fused` at all, so what it ships is
    // `stepped + throughput` — a config this tool could not previously
    // render, which meant every WER number here described a mouth the
    // PHONE never uses. `--speech=throughput` renders the phone's exact
    // levers on this Mac, so a Mac ear can judge what the phone speaks.
    let stepped = NeuralVoice(variant: werModel,
                              renderingOn: AudioEnginePlaybackHost(engine: steppedEngine),
                              lead: lead, multiCodeDecoderMode: .stepped,
                              speechDecoderMode: werLevers.vocoder)
    let fused = NeuralVoice(variant: werModel,
                            renderingOn: AudioEnginePlaybackHost(engine: fusedEngine),
                            lead: lead, multiCodeDecoderMode: .fused,
                            speechDecoderMode: werLevers.vocoder)
    return Mouths(levers: werLevers, stepped: stepped, fused: fused)
}

@MainActor
private func werAudioDirectory(_ arguments: [String]) -> URL? {
    // `--save-audio=DIR` writes every graded capture as a WAV, so the ear
    // ruling AC-163 asks for does not depend on standing beside this Mac
    // while it speaks. Off by default: a measurement tool should not
    // litter unless asked.
    let audioDirectory: URL? = arguments
        .first { $0.hasPrefix("--save-audio=") }
        .map { URL(filePath: String($0.dropFirst("--save-audio=".count))) }
    if let audioDirectory {
        try? FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
    }
    return audioDirectory
}

@MainActor
private func werWarmUp(draws: Int, stepped: NeuralVoice, fused: NeuralVoice,
                       whisper: WhisperEngine) async {
    print("\n📝  ROUND-TRIP WER (AC-103, the objective half)")
    print("    speak → capture at the mixer → transcribe → WER")
    print("    \(draws) draws per neural mouth per sentence, because the voice")
    print("    is non-deterministic in length (INSTRUMENTS §11, §13).\n")

    print("    loading…")
    do {
        try await stepped.ensureModel(); try await fused.ensureModel()
    } catch { print("load failed: \(error)"); exit(1) }
    _ = try? await measure(stepped, "Warming up.")
    _ = try? await measure(fused, "Warming up.")
    _ = try? await BakeoffHarness.measure(engine: whisper, label: "warmup",
                                          samples: [Float](repeating: 0, count: 16000),
                                          sampleRate: 16000, reference: "warm up")
}

/// One graded draw: which mouth said it, where it sits in the run, and
/// what the transcriber made of it.
private struct Row { let mouth: String; let sentence: Int; let draw: Int
                     let wer: Double; let heard: String }

/// One capture handed to the grader — the six things a graded draw is,
/// named rather than counted out at every call.
private struct GradedCapture {
    let mouth: String
    let sentenceIndex: Int
    let draw: Int
    let samples: [Float]
    let rate: Double
    let reference: String
}

/// The grader: it owns the transcriber, the optional WAV directory, and
/// the rows every graded draw adds to.
@MainActor
private final class Grader {
    let whisper: WhisperEngine
    let audioDirectory: URL?
    private(set) var rows: [Row] = []

    init(whisper: WhisperEngine, audioDirectory: URL?) {
        self.whisper = whisper
        self.audioDirectory = audioDirectory
    }

    func saveWav(_ samples: [Float], rate: Double, named name: String) -> String? {
        guard let audioDirectory, rate > 0, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!,
                                               count: samples.count)
        }
        let url = audioDirectory.appending(path: "\(name).wav")
        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
            return url.lastPathComponent
        } catch {
            FileHandle.standardError.write(
                Data("   could not save \(name).wav: \(error)\n".utf8))
            return nil
        }
    }

    func grade(_ capture: GradedCapture) async {
        let mouth = capture.mouth
        let sentenceIndex = capture.sentenceIndex
        let draw = capture.draw
        let samples = capture.samples
        let rate = capture.rate
        let reference = capture.reference
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
        let saved = saveWav(samples, rate: rate,
                            named: "s\(sentenceIndex + 1)-\(mouth)-draw\(draw)")
        do {
            let measured = try await BakeoffHarness.measure(
                engine: whisper, label: mouth,
                samples: samples, sampleRate: rate, reference: reference)
            rows.append(Row(mouth: mouth, sentence: sentenceIndex, draw: draw,
                            wer: measured.score.wer, heard: measured.text))
            print(String(format: "      %-8@ draw %d — WER %.3f — %.2f s, peak %.3f — \"%@\"%@",
                         mouth as NSString, draw, measured.score.wer, seconds, peak,
                         measured.text as NSString,
                         saved.map { " → \($0)" } ?? "" as NSString as String))
        } catch {
            print("      \(mouth): transcription failed — \(error)")
        }
    }
}

/// Everything one draw-loop needs: the two mouths, the taps that hear
/// them, and the grader that scores what they said.
private struct Bench {
    let stepped: NeuralVoice
    let fused: NeuralVoice
    let steppedCapture: MixerCapture
    let fusedCapture: MixerCapture
    let grader: Grader
}

@MainActor
private func werRunDraws(sentences: [String], draws: Int, bench: Bench) async {
    let stepped = bench.stepped
    let fused = bench.fused
    let steppedCapture = bench.steppedCapture
    let fusedCapture = bench.fusedCapture
    let grader = bench.grader
    for (index, text) in sentences.enumerated() {
        print("\n  sentence \(index + 1): \"\(text)\"")

        // Apple's mouth, once: it is deterministic, so extra draws would
        // measure nothing. Captured through `write` rather than the tap,
        // because it does not render through our engine — same voice,
        // not the identical code path we ship.
        if let appleAudio = await captureApple(text) {
            await grader.grade(GradedCapture(
                mouth: "apple", sentenceIndex: index, draw: 1,
                samples: appleAudio.samples, rate: appleAudio.sampleRate,
                reference: text))
        } else {
            print("      apple: write produced nothing — not graded")
        }

        for draw in 1...draws {
            steppedCapture.record()
            _ = try? await measure(stepped, text)
            let steppedAudio = steppedCapture.stop()
            await grader.grade(GradedCapture(
                mouth: "stepped", sentenceIndex: index, draw: draw,
                samples: steppedAudio, rate: steppedCapture.sampleRate,
                reference: text))

            fusedCapture.record()
            _ = try? await measure(fused, text)
            let fusedAudio = fusedCapture.stop()
            await grader.grade(GradedCapture(
                mouth: "fused", sentenceIndex: index, draw: draw,
                samples: fusedAudio, rate: fusedCapture.sampleRate,
                reference: text))
        }
    }
}

@MainActor
private func werTable(rows: [Row], levers: VoiceLevers, lead: Duration) {
    print("\n════════════════════════════════════════════════")
    print("neural model under test: \(levers.model == .qwen3TTS_1_7b ? "1.7B" : "0.6B")"
        + " · vocoder \(levers.vocoder == .throughputOptimized ? "throughput" : "latency")"
        + " · lead \(lead)")
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
}
