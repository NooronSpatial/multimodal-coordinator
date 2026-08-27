// The `cushion-sweep` instrument: 4o's proof (AC-178).
//
// It answers three questions with one pass, and the third is the one
// §143a left open:
//
//   1. Does a bigger cushion actually remove the dropouts? Measured as
//      DIGITAL SILENCE — exact-zero runs, the metric with no threshold to
//      be wrong about (the amplitude floor the review killed).
//   2. What does that cushion COST? F-2 banked the whole worst stall on
//      the argument that a fraction is a guess; the felt pause is the
//      price, and this prints it beside the silence so the fork can be
//      re-ruled with numbers instead of taste.
//   3. Does a cushion sized on a SHORT reply survive a LONG one? The new
//      rule sizes from the last reply's stall and does not scale with
//      length (§143a). Two sentence lengths, so the question is asked.

import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTTS
import TTSKit

/// One sentence to sweep, and how long it is meant to be.
private struct Fixture {
    let name: String
    let text: String
}

@MainActor
func runCushionSweep(_ arguments: [String]) async -> Never {
    let levers: VoiceLevers
    do {
        levers = try VoiceLevers.parsed(fromArguments: arguments)
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("bakeoff: \(refusal.message)\n".utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data("bakeoff: \(error)\n".utf8))
        exit(2)
    }

    // The cushions to try. Zero first, because a sweep that never shows
    // the disease cannot claim to have cured it.
    let cushions: [Duration] = [.zero, .milliseconds(200), .milliseconds(400),
                                .milliseconds(800), .milliseconds(1600),
                                .milliseconds(3200)]
    let fixtures = [
        Fixture(name: "short", text: "The audio travels through a ring buffer."),
        // Long, because §143a's question is whether a cushion learned on
        // the short one survives this.
        Fixture(name: "long", text: "The audio travels through a ring buffer "
            + "into a pump that cuts it into small chunks, and each chunk is "
            + "handed to a listener that decides whether the person is still "
            + "speaking or has finally stopped and is waiting for an answer.")
    ]

    print("\n🛏  CUSHION SWEEP (AC-178) — serial, release, one machine")
    print("    silence = EXACT-ZERO runs ≥20 ms inside the speech span")
    print("    (an amplitude threshold was tried and proved an artifact, §53)")
    print("\n| fixture | cushion | speech | silence runs | silence ms/s | felt pause |")
    print("|---|---|---|---|---|---|")

    for fixture in fixtures {
        for cushion in cushions {
            await sweepOne(fixture: fixture, cushion: cushion, levers: levers)
        }
    }
    print("\nThe smallest cushion whose silence column reads 0 is the answer")
    print("AC-178 asks for. Read the felt pause beside it: that is what it costs.")
    exit(0)
}

@MainActor
private func sweepOne(fixture: Fixture, cushion: Duration,
                      levers: VoiceLevers) async {
    // ONE ENGINE PER RUN. voice-wer learned this the hard way: sharing an
    // engine put a fused utterance immediately after a stepped teardown
    // detaching from the same graph, and three captures came back empty.
    let engine = AVAudioEngine()
    let capture = MixerCapture(engine: engine)
    let voice = NeuralVoice(variant: levers.model,
                            renderingOn: AudioEnginePlaybackHost(engine: engine),
                            lead: cushion,
                            multiCodeDecoderMode: levers.decoder,
                            speechDecoderMode: levers.vocoder,
                            temperature: levers.temperature,
                            seed: 20260816)
    guard (try? await voice.ensureModel()) != nil else {
        print("| \(fixture.name) | \(cushion) | LOAD FAILED |")
        return
    }
    // Warm-up, excluded: the first decode after a load compiles graphs,
    // the same rule voice-levers and voice-spike follow.
    _ = try? await measure(voice, "Warming up.")

    capture.record()
    let timing = try? await measure(voice, fixture.text)
    let samples = capture.stop()
    await voice.retire()

    guard !samples.isEmpty, capture.sampleRate > 0 else {
        print("| \(fixture.name) | \(cushion) | CAPTURED NOTHING — not graded |")
        return
    }
    let silence = DigitalSilence.measure(samples: samples,
                                         sampleRate: capture.sampleRate)
    // The felt pause a person actually waits: the cushion banked before
    // playback starts, plus the decode that had to happen first.
    let feltPause = timing.map { $0.firstAudio } ?? -1
    print(String(format: "| %@ | %@ | %.2f s | %d | %.0f | %.0f ms |",
                 fixture.name, "\(cushion)", silence.spanMilliseconds / 1000,
                 silence.runs, silence.millisecondsPerSecond, feltPause))
}
