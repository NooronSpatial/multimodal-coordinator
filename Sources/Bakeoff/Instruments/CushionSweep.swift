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

    // COUNTERBALANCED REPEATS, because the first version of this sweep
    // measured the machine and not the lever.
    //
    // Running cushions in order confounds cushion size with elapsed time,
    // and this Mac slows as it heats: the same long sentence took 33 s in
    // one run and 53 s in another. The tell was that a BIGGER cushion
    // appeared to produce MORE silence — and a reverse-order control
    // showed the numbers rising with POSITION in both directions, which
    // is drift, not the cushion.
    //
    // So each repeat sweeps the opposite way. A cushion measured early in
    // one pass is measured late in the next, and a linear drift cancels
    // in the pair. That is the whole reason `--repeats` defaults to an
    // EVEN number: an odd count leaves one unpaired pass and the bias
    // comes back.
    // COOLDOWN BETWEEN RUNS, and it is the difference between a valid
    // measurement and a void one.
    //
    // The counterbalanced sweep answered the SHORT fixture and could say
    // nothing about the long one: its drift probe moved 351 ms/s while
    // the six cushions differed by 25, and its final run took 89.75 s for
    // a sentence worth about 30. Sustained decoding heats this Mac faster
    // than a sweep can outrun, so the machine — not the lever — becomes
    // the loudest variable.
    //
    // A sleep in a MEASUREMENT tool is not the banned pattern: the ban is
    // on tests waiting for time instead of for a fact. Here the wait IS
    // the fact being controlled for.
    let cooldown = arguments.first { $0.hasPrefix("--cooldown=") }
        .flatMap { Double($0.dropFirst("--cooldown=".count)) } ?? 0
    let repeats = arguments.first { $0.hasPrefix("--repeats=") }
        .flatMap { Int($0.dropFirst("--repeats=".count)) } ?? 2
    guard repeats % 2 == 0, repeats > 0 else {
        let complaint = "bakeoff: --repeats must be EVEN — an odd count"
            + " leaves a pass unpaired and the drift it exists to cancel"
            + " comes back\n"
        FileHandle.standardError.write(Data(complaint.utf8))
        exit(2)
    }

    if cooldown > 0 {
        print(String(format: "    cooling %.0f s between runs, so the machine"
                     + " is not the loudest variable", cooldown))
    }
    for fixture in fixtures {
        await sweepFixture(fixture, cushions: cushions, repeats: repeats,
                           levers: levers, cooldown: cooldown)
    }
    print("\nThe smallest cushion whose MEDIAN silence reads 0 is the answer")
    print("AC-178 asks for — but ONLY from a cell with every run present.")
    print("A cell marked ONE RUN is a single sample wearing a median's clothes,")
    print("which is how 800 ms was published and then withdrawn (§54.3a).")
    print("Read the drift probe first: it says how much to trust the rest.")
    exit(0)
}

/// One fixture, swept with its repeats and bracketed by drift probes.
@MainActor
private func sweepFixture(_ fixture: Fixture, cushions: [Duration],
                          repeats: Int, levers: VoiceLevers,
                          cooldown: Double) async {
    var rows: [Row] = []
    do {
        // THE DRIFT PROBE. One fixed cushion, measured before and after
        // everything else, so the machine's degradation is SHOWN rather
        // than inferred. If these two disagree, every number between them
        // carries that much doubt — and the reader can see how much.
        let driftBefore = await sweepOne(fixture: fixture, cushion: .milliseconds(800),
                                         levers: levers, label: "drift probe (before)")
        for pass in 0..<repeats {
            let order = pass.isMultiple(of: 2) ? cushions : cushions.reversed()
            for cushion in order {
                if let row = await sweepOne(fixture: fixture, cushion: cushion,
                                            levers: levers, label: nil,
                                            cooldown: cooldown) {
                    rows.append(row)
                }

            }
        }
        let driftAfter = await sweepOne(fixture: fixture, cushion: .milliseconds(800),
                                        levers: levers, label: "drift probe (after)")
        report(fixture: fixture, rows: rows, cushions: cushions,
               driftBefore: driftBefore, driftAfter: driftAfter)
    }
}

/// One measured run.
private struct Row {
    let cushionMilliseconds: Int
    let silencePerSecond: Double
    let feltPauseMilliseconds: Double
    let spanSeconds: Double
}

/// The per-fixture table: one line per cushion, medians across repeats,
/// with the spread shown rather than averaged away.
@MainActor
private func report(fixture: Fixture, rows: [Row], cushions: [Duration],
                    driftBefore: Row?, driftAfter: Row?) {
    print("\n### \(fixture.name)")
    if let driftBefore, let driftAfter {
        // The machine's own change, in the units of the thing being
        // measured. A reader who sees 60 here should not believe a 40 ms/s
        // difference between two cushions.
        print(String(format:
            "drift probe @800 ms — before %.0f ms/s · after %.0f ms/s · moved %.0f",
            driftBefore.silencePerSecond, driftAfter.silencePerSecond,
            abs(driftAfter.silencePerSecond - driftBefore.silencePerSecond)))
    }
    print("| cushion | runs | silence ms/s (median) | spread | felt pause (median) |")
    print("|---|---|---|---|---|")
    for cushion in cushions {
        let mine = rows.filter { $0.cushionMilliseconds == cushion.milliseconds }
        guard !mine.isEmpty else { continue }
        let silences = mine.map(\.silencePerSecond).sorted()
        let pauses = mine.map(\.feltPauseMilliseconds).sorted()
        // A SINGLE SURVIVING RUN IS MARKED, because it reads exactly like
        // a repeated zero and is not one. §54.2 published 800 ms as the
        // answer from a cell that captured one of its two runs; §54.3a
        // corrected it to 1600 ms. The reader is told which cells can do
        // that again.
        let single = mine.count < 2 ? "  ⚠ ONE RUN" : ""
        print(String(format: "| %d ms | %d | %.0f | %.0f–%.0f | %.0f ms |%@",
                     cushion.milliseconds, mine.count,
                     median(silences), silences.first ?? 0, silences.last ?? 0,
                     median(pauses), single))
    }
}

private func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

@discardableResult
@MainActor
private func sweepOne(fixture: Fixture, cushion: Duration,
                      levers: VoiceLevers, label: String?,
                      cooldown: Double = 0) async -> Row? {
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
        return nil
    }
    // Warm-up, excluded: the first decode after a load compiles graphs,
    // the same rule voice-levers and voice-spike follow.
    _ = try? await measure(voice, "Warming up.")

    // THE COOLDOWN GOES HERE, not between rows. The first version rested
    // BEFORE the model load and the warm-up decode, so the machine
    // reheated during exactly the work the rest was meant to protect —
    // it cooled, then did two expensive things, then measured. Resting
    // immediately before the measured decode is the only placement that
    // does what the flag claims.
    if cooldown > 0 {
        try? await Task.sleep(for: .seconds(cooldown))
    }

    capture.record()
    let timing = try? await measure(voice, fixture.text)
    let samples = capture.stop()
    await voice.retire()

    // A BROKEN RUN IS NOT A PERFECT ONE, and it used to score as one.
    //
    // `DigitalSilence` returns 0 ms/s for flawless speech AND for no
    // speech at all, and the old guard could not tell them apart: the
    // engine keeps rendering zeros after a decode dies, so `samples` is
    // never empty. A reply that threw two seconds in was graded 0 — the
    // best possible score — and folded into the median that decided
    // between 800 ms and 1600 ms.
    //
    // `AdaptiveLead` has guarded exactly this since 4m (`guard
    // margin.completed`); the sweep now does too.
    guard timing?.completed == true else {
        print("| \(fixture.name) | \(cushion) | DECODE FAILED — not graded |")
        return nil
    }
    guard !samples.isEmpty, capture.sampleRate > 0 else {
        print("| \(fixture.name) | \(cushion) | CAPTURED NOTHING — not graded |")
        return nil
    }
    // A run that produced no audible span is not a silent-free run: it is
    // a run with nothing in it, and grading it 0 would be the §30 fault
    // wearing the metric's clothes.
    guard DigitalSilence.measure(samples: samples,
                                 sampleRate: capture.sampleRate)
        .spanMilliseconds > 0 else {
        print("| \(fixture.name) | \(cushion) | NO AUDIBLE SPAN — not graded |")
        return nil
    }
    let silence = DigitalSilence.measure(samples: samples,
                                         sampleRate: capture.sampleRate)
    // The felt pause a person actually waits: the cushion banked before
    // playback starts, plus the decode that had to happen first.
    // −1 never reaches a median now: a run without a first-audio stamp
    // is not graded at all (the guard above), so this is always real.
    let feltPause = timing?.firstAudio ?? -1
    if let label {
        print(String(format: "  %@ · %@: %.0f ms/s over %.2f s",
                     fixture.name, label, silence.millisecondsPerSecond,
                     silence.spanMilliseconds / 1000))
    }
    return Row(cushionMilliseconds: cushion.milliseconds,
               silencePerSecond: silence.millisecondsPerSecond,
               feltPauseMilliseconds: feltPause,
               spanSeconds: silence.spanMilliseconds / 1000)
}
