// The `voice-kokoro` instrument (4q, AC-183 + AC-184): the adopted mouth,
// measured the way the first mouth was — speak → capture at the mixer →
// exact-zero runs (digital silence) → transcribe → WER.
//
//   swift run -c release bakeoff voice-kokoro --kokoro-weights=DIR [--draws=N] [--save-audio=DIR]
//
// SAME TEXT AS THE OTHER INSTRUMENTS, character for character: the
// cushion sweep's short and long fixtures (§53/§54) and voice-wer's three
// sentences (§32/§48). Different text would give numbers that cannot be
// laid beside the ones already in INSTRUMENTS, which is the whole reason
// this file exists.
//
// ONE ENGINE PER DRAW, the sweep's correction: sharing an engine once put
// a decode immediately after another's teardown detaching from the same
// graph, and three captures came back empty. And the guards are the
// sweep's guards — a decode that failed, a tap that caught nothing, or a
// capture with no audible span is NOT graded, because `DigitalSilence`
// returns 0 ms/s for flawless speech AND for no speech at all.
import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitTTS
import MultiModalKitWhisper
import Synchronization

/// One capture handed to the grader — the things a graded draw is, named
/// rather than counted out at every call (voice-wer's own shape, and the
/// linter's five-parameter bound).
private struct KokoroCapture {
    let fixture: (name: String, text: String)
    let draw: Int
    let samples: [Float]
    let rate: Double
    let firstAudioMs: Double
    let margin: DecodeMargin?
    let warmUp: Double?
}

/// What one draw is, once it has been graded.
private struct KokoroRow {
    let fixture: String; let draw: Int
    let audioSeconds: Double; let firstAudioMs: Double
    /// DECODE wall ÷ audio, from the run's own margin — not
    /// `Timing.total ÷ audio`, which the first draft printed as "RTF" and
    /// which is PLAYBACK: `total` runs to `.finished`, and by D-029
    /// finished means the room is quiet. Every row read 1.00 and the
    /// column was measuring the speaker, not the decoder.
    let decodeRTF: Double?
    /// The pure first-decode stamp (D-087 = A), on the Mac.
    let firstDecodeMs: Double?
    let silenceRuns: Int; let silenceMsPerSecond: Double
    let wer: Double; let heard: String
    let warmUpMs: Double?
}

private struct KokoroFlags {
    let weights: KokoroWeights
    let draws: Int
    let audioDirectory: URL?

    init(_ arguments: [String]) {
        func flag(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        weights = flag("kokoro-weights").map { KokoroWeights(directory: URL(fileURLWithPath: $0)) }
            ?? .inApplicationSupport()
        draws = max(1, flag("draws").flatMap(Int.init) ?? 2)
        audioDirectory = flag("save-audio").map { URL(fileURLWithPath: $0) }
        if let audioDirectory {
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
    }
}

private let kokoroFixtures: [(name: String, text: String)] = [
    ("short", "The audio travels through a ring buffer."),
    ("long", "The audio travels through a ring buffer "
        + "into a pump that cuts it into small chunks, and each chunk is "
        + "handed to a listener that decides whether the person is still "
        + "speaking or has finally stopped and is waiting for an answer."),
    ("wer1", "How is the weather today?"),
    ("wer2", "I can hear you. Say that again and I will stop talking."),
    ("wer3", "The audio travels through a ring buffer into a pump that cuts it into small chunks.")
]

func runVoiceKokoro(_ arguments: [String]) async {
    let flags = KokoroFlags(arguments)
    let weights = flags.weights
    print("\n🗣  VOICE-KOKORO (AC-183 + AC-184) — one engine per draw, release build")
    print("    speak → capture at the mixer → exact-zero runs ≥20 ms → transcribe → WER")
    print("    weights: \(weights.directory.path(percentEncoded: false)) · \(weights.precision.rawValue)")
    // DAMAGE ONLY. The first version printed `missingReport()`, which is
    // also true for the fp16 cast that has simply not been built yet —
    // so a normal first run opened with a warning about a file it was
    // about to create. Absent weights are fetched by `ensureModel()`; a
    // WRONG-SIZED file is the case worth stopping for, because the vendor
    // force-tries its load and would crash instead of throwing.
    if let damage = weights.damagedReport() {
        print("    ⚠ \(damage)")
    }
    let whisper = WhisperEngine()
    guard await whisper.modelInstalled() else {
        print("whisper's model is not installed — the grader is missing, so nothing is graded")
        exit(1)
    }

    var rows: [KokoroRow] = []
    var graderWarm = false
    for fixture in kokoroFixtures {
        for draw in 1...flags.draws {
            if let row = await kokoroDraw(fixture, draw: draw, flags: flags,
                                          whisper: whisper, graderWarm: &graderWarm) {
                rows.append(row)
            }
        }
    }
    printKokoroReport(rows)
    // The other instruments end the process; without this, main.swift
    // falls through into the default bake-off and reads `--kokoro-weights`
    // as a WAV path.
    exit(0)
}

/// One draw: a fresh engine, a fresh voice, one capture, both gradings.
/// `nil` when it must not be graded, with the reason already printed.
private func kokoroDraw(_ fixture: (name: String, text: String), draw: Int,
                        flags: KokoroFlags, whisper: WhisperEngine,
                        graderWarm: inout Bool) async -> KokoroRow? {
    let engine = AVAudioEngine()
    let capture = MixerCapture(engine: engine)
    let voice = KokoroVoice(weights: flags.weights)
    await voice.render(on: AudioEnginePlaybackHost(engine: engine))
    let margin = Mutex<DecodeMargin?>(nil)
    await voice.reportMargins { reported in margin.withLock { $0 = reported } }
    do {
        // Load, cast if needed, and D-085's warm-up — all EXCLUDED from
        // the measured decode, exactly as the app pays them at launch
        // rather than in the first reply.
        try await voice.ensureModel()
    } catch {
        print("| \(fixture.name) | \(draw) | LOAD FAILED — \(error) |"); return nil
    }
    let warmUp = voice.coldStart.warmUpMilliseconds

    capture.record()
    let timing = try? await measure(voice, fixture.text)
    let samples = capture.stop()
    await voice.retire()

    guard let timing, timing.completed else {
        print("| \(fixture.name) | \(draw) | DECODE FAILED — not graded |"); return nil
    }
    guard !samples.isEmpty, capture.sampleRate > 0 else {
        print("| \(fixture.name) | \(draw) | CAPTURED NOTHING — not graded |"); return nil
    }
    return await kokoroGrade(KokoroCapture(fixture: fixture, draw: draw, samples: samples,
                                           rate: capture.sampleRate, firstAudioMs: timing.firstAudio,
                                           margin: margin.withLock { $0 }, warmUp: warmUp),
                             flags: flags, whisper: whisper, graderWarm: &graderWarm)
}

/// The grading half of a draw: the two metrics over one capture. Split
/// from `kokoroDraw` at the linter's 50-line bound, at the seam where
/// the microphone-side work ends and the scoring begins.
private func kokoroGrade(_ capture: KokoroCapture, flags: KokoroFlags,
                         whisper: WhisperEngine, graderWarm: inout Bool) async -> KokoroRow? {
    let (fixture, draw, samples, rate) = (capture.fixture, capture.draw, capture.samples, capture.rate)
    let (firstAudioMs, reported, warmUp) = (capture.firstAudioMs, capture.margin, capture.warmUp)
    let silence = DigitalSilence.measure(samples: samples, sampleRate: rate)
    guard silence.spanMilliseconds > 0 else {
        print("| \(fixture.name) | \(draw) | NO AUDIBLE SPAN — not graded |"); return nil
    }
    if !graderWarm {
        // The grader's first transcription compiles CoreML graphs; it is
        // paid on THIS capture's twin and thrown away so no graded row
        // carries it.
        _ = try? await BakeoffHarness.measure(engine: whisper, label: "warm", samples: samples,
                                              sampleRate: rate, reference: fixture.text)
        graderWarm = true
    }
    guard let measured = try? await BakeoffHarness.measure(
        engine: whisper, label: "kokoro",
        samples: samples, sampleRate: rate, reference: fixture.text)
    else {
        print("| \(fixture.name) | \(draw) | TRANSCRIPTION FAILED — not graded |"); return nil
    }
    if let audioDirectory = flags.audioDirectory {
        saveWav(samples, rate: rate,
                to: audioDirectory.appending(path: "\(fixture.name)-draw\(draw).wav"))
    }
    let row = KokoroRow(fixture: fixture.name, draw: draw,
                        audioSeconds: Double(samples.count) / rate,
                        firstAudioMs: firstAudioMs,
                        decodeRTF: reported.map { $0.wallMilliseconds / $0.audioMilliseconds },
                        firstDecodeMs: reported?.firstDecodeMilliseconds,
                        silenceRuns: silence.runs, silenceMsPerSecond: silence.millisecondsPerSecond,
                        wer: measured.score.wer, heard: measured.text, warmUpMs: warmUp)
    print(String(format: "  %@ draw %d · %.1f s · first audio %.0f ms · decode RTF %@ · 1st decode %@ ms",
                 row.fixture as NSString, row.draw, row.audioSeconds, row.firstAudioMs,
                 kokoroText(row.decodeRTF, "%.2f") as NSString, kokoroText(row.firstDecodeMs, "%.0f") as NSString)
          + String(format: " · silence %d runs, %.1f ms/s · WER %.3f",
                   row.silenceRuns, row.silenceMsPerSecond, row.wer))
    return row
}

private func kokoroText(_ value: Double?, _ format: String) -> String {
    value.map { String(format: format, $0) } ?? "—"
}

private func printKokoroReport(_ rows: [KokoroRow]) {
    print("\n| fixture | draw | audio s | first audio ms | decode RTF | 1st decode ms"
          + " | silence runs | silence ms/s | WER | warm-up ms |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for row in rows {
        print(String(format: "| %@ | %d | %.1f | %.0f | %@ | %@ | %d | %.1f | %.3f | %@ |",
                     row.fixture as NSString, row.draw, row.audioSeconds, row.firstAudioMs,
                     kokoroText(row.decodeRTF, "%.2f") as NSString,
                     kokoroText(row.firstDecodeMs, "%.0f") as NSString,
                     row.silenceRuns, row.silenceMsPerSecond, row.wer,
                     kokoroText(row.warmUpMs, "%.0f") as NSString))
    }
    print("\nheard, per row:")
    for row in rows { print("  \(row.fixture) draw \(row.draw): \"\(row.heard)\"") }
    let silent = rows.filter { $0.silenceRuns == 0 }.count
    print(String(format: "\n%d of %d graded draws had ZERO exact-silence runs at lead .zero (AC-183).",
                 silent, rows.count))
    guard !rows.isEmpty else { return }
    let wers = rows.map(\.wer).sorted()
    print(String(format: "median WER across graded draws: %.3f (AC-184)", wers[wers.count / 2]))
    let rtfs = rows.compactMap(\.decodeRTF).sorted()
    if !rtfs.isEmpty {
        print(String(format: "median decode RTF: %.2f (wall ÷ audio, from the run's margin)",
                     rtfs[rtfs.count / 2]))
    }
}

private func saveWav(_ samples: [Float], rate: Double, to url: URL) {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    guard let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
    try? file.write(from: buffer)
}
