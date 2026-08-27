// The `voice-selfecho` instrument: the shielded neural voice on the live
// capture engine, with the microphone side read while it speaks.
import Foundation
import MultiModalKit
import MultiModalKitTTS

// `swift run bakeoff voice-selfecho` — CAN THE ASSISTANT HEAR ITSELF? (4k, AC-154)
//
// The phone's self-barge (§37, §38) is a microphone-side question: while
// the reply plays, does mic energy cross the 0.021 gate? The echo probe
// cannot answer it for the SHIELDED arrangement — it predates the shield
// and speaks through a bare AVSpeechSynthesizer. voice-onmic cannot either:
// it proves the reply RENDERS, and never reads the microphone side at all.
// So this instrument is both halves at once: the shielded neural voice on
// the live capture engine, and the ring being read while it speaks.
//
// THE CONTROL IS THE POINT (D-054 rule 5): run it with --no-shield and the
// voice renders on its OWN engine, where the canceller cannot see it. An
// instrument that reports "clean" must be able to show "leaking" on demand,
// or its clean is indistinguishable from blindness.
//
// §23's caveat carries over verbatim: a Mac graph verdict does not transfer
// to the phone. This develops the METHOD and the fix's before/after; the
// phone's own `echo?` rows convict.
@MainActor
func runVoiceSelfEcho(_ arguments: [String]) async throws {
    let flags = selfEchoFlags(arguments)
    let shielded = flags.shielded
    let rawMicrophone = flags.rawMicrophone
    let gate = flags.gate

    let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 17)
    let microphone = MicrophoneSource(voiceProcessing: !rawMicrophone,
                                      hostsPlayback: shielded)
    do { try microphone.start(into: producer) } catch { print("❌ capture would not start: \(error)"); exit(1) }
    // ASKED FOR is not GOT — the echo probe's lesson. Without this line a
    // loud residual is ambiguous between "canceller refused" and
    // "canceller running but never shown the reply".
    print("    voice processing: \(microphone.voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")")

    let voice = NeuralVoice(renderingOn: shielded ? microphone.playbackHost : nil)
    guard await voice.modelInstalled() else {
        print("❌ the neural model is not installed — run: swift run bakeoff voice-install")
        microphone.stop(); exit(1)
    }
    do { try await voice.ensureModel() } catch { print("❌ load failed: \(error)"); microphone.stop(); exit(1) }

    // The measuring loop is the echo probe's, verbatim in spirit: the pump
    // is not running, so this is the ring's sole reader and the raw truth.
    let meter = EchoMeter(consumer: consumer, gate: gate)

    await selfEchoQuiet(meter)

    let speaking = try await selfEchoSpeak(voice: voice, meter: meter)

    let leakWindows = speaking.filter { $0.peak > gate }.count
    print("")
    selfEchoVerdict(rawMicrophone: rawMicrophone, microphone: microphone,
                    leakWindows: leakWindows)
    microphone.stop()
    exit(0)
}

/// The three levers this instrument runs on.
private struct EchoFlags {
    let shielded: Bool
    let rawMicrophone: Bool
    let gate: Float
}

@MainActor
private func selfEchoFlags(_ arguments: [String]) -> EchoFlags {
    let shielded = !arguments.contains("--no-shield")
    // THE EYES CONTROL. The first runs of this instrument found that
    // macOS's voice-processing unit cancels SYSTEM-WIDE output — even a
    // reply on the voice's own engine came back at the quiet-room level,
    // where the same arrangement on iOS measured peak 1.0 (§23). So on a
    // Mac the shield/no-shield pair cannot prove the instrument can see.
    // --no-vp turns voice processing off entirely: a raw microphone MUST
    // hear the speaker, or the instrument is blind and every "clean" it
    // ever printed was worthless.
    let rawMicrophone = arguments.contains("--no-vp")
    let gate: Float = arguments.first(where: { $0.hasPrefix("--gate=") })
        .flatMap { Float($0.dropFirst("--gate=".count)) } ?? 0.021

    print("\n🪞  SELF-ECHO (AC-154) — does the assistant's voice cross its own gate?")
    let arrangement = rawMicrophone
        ? "RAW MIC (--no-vp) — the eyes control: this MUST leak"
        : (shielded ? "SHIELDED — reply on the capture engine"
                    : "no shield — reply on the voice's OWN engine")
    print("    arrangement: \(arrangement)")
    print("    gate: \(gate)  (the demo's default is 0.021)\n")
    return EchoFlags(shielded: shielded, rawMicrophone: rawMicrophone, gate: gate)
}

/// The ring's SOLE reader while this instrument runs: the scratch it reads
/// into, and the gate every window is judged against.
@MainActor
private final class EchoMeter {
    private let consumer: AudioRingConsumer
    private var scratch: [Float]
    private let gate: Float

    init(consumer: AudioRingConsumer, gate: Float) {
        self.consumer = consumer
        self.scratch = [Float](repeating: 0, count: consumer.capacity)
        self.gate = gate
    }

    func window() -> (peak: Float, rms: Float) {
        var peak: Float = 0
        var sumOfSquares: Float = 0
        var frames = 0
        scratch.withUnsafeMutableBufferPointer { buffer in
            let result = consumer.read(into: buffer)
            for index in 0..<result.framesRead {
                let sample = buffer[index]
                peak = max(peak, abs(sample))
                sumOfSquares += sample * sample
            }
            frames = result.framesRead
        }
        return (peak, (sumOfSquares / Float(max(frames, 1))).squareRoot())
    }

    func report(_ label: String, _ windows: [(peak: Float, rms: Float)]) {
        let over = windows.filter { $0.peak > gate }.count
        let peak = windows.map(\.peak).max() ?? 0
        let worstRMS = windows.map(\.rms).max() ?? 0
        print(String(format: "    %@  peak %.4f · worst rms %.4f · %d of %d windows over the gate",
                     label, peak, worstRMS, over, windows.count))
        // WHEN, not only how many — the discriminator between the suspects
        // (§23): residual-over-gate leaks SPREAD across the reply;
        // convergence and the attach transient CLUSTER at its start.
        let crossings = windows.enumerated().filter { $0.element.peak > gate }
        if !crossings.isEmpty && crossings.count < windows.count {
            let timeline = crossings
                .map { String(format: "%.2fs@%.3f", Double($0.offset) * 0.25, $0.element.peak) }
                .joined(separator: "  ")
            print("      over the gate at: \(timeline)")
        }
    }
}

@MainActor
private func selfEchoQuiet(_ meter: EchoMeter) async {
    // DRAIN FIRST, and the first run is why. The ring has been filling
    // since the microphone started — through the whole model load — so the
    // first read returned minutes of backlog and called the quiet room
    // peak 0.61. A baseline that contains the past is not a baseline.
    _ = meter.window()
    print("    measuring the quiet room (2 s) — stay quiet…")
    var quiet: [(peak: Float, rms: Float)] = []
    for _ in 0..<8 {
        try? await Task.sleep(for: .milliseconds(250))
        quiet.append(meter.window())
    }
    meter.report("quiet room:     ", quiet)
}

@MainActor
private func selfEchoSpeak(voice: NeuralVoice,
                           meter: EchoMeter) async throws -> [(peak: Float, rms: Float)] {
    // ONE long sentence, the bench's own, so the phone and the Mac measure
    // the same work. The reader samples every 250 ms UNTIL the terminal —
    // gated on the fact of finishing, never on a duration guess.
    print("    speaking — stay quiet…")
    let run = try await voice.openUtterance()
    let feeder = Task {
        await run.feed("The audio travels through a ring buffer into a pump "
            + "that cuts it into small chunks.")
        await run.finishTokens()
    }
    let sampler = Task { () -> [(peak: Float, rms: Float)] in
        var samples: [(peak: Float, rms: Float)] = []
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            samples.append(meter.window())
        }
        return samples
    }
    var failure: String?
    for await update in run.updates {
        if case .failed(let why) = update { failure = why }
    }
    await feeder.value
    sampler.cancel()
    let speaking = await sampler.value
    if let failure { print("    ⚠️  decode failed: \(failure)") }
    meter.report("while speaking: ", speaking)
    return speaking
}

@MainActor
private func selfEchoVerdict(rawMicrophone: Bool, microphone: MicrophoneSource,
                             leakWindows: Int) {
    if rawMicrophone {
        print(leakWindows > 0
            ? "    EYES: proven — the raw microphone heard the voice "
                + "(\(leakWindows) windows over the gate). Cancelled runs mean something."
            : "    EYES: FAILED — a raw microphone did not hear the voice. Either "
                + "the output is silent or this instrument is blind; NO other run "
                + "of it can be trusted until this one leaks.")
    } else if !microphone.voiceProcessingActive {
        print("    VERDICT: unusable — the platform refused voice processing, so")
        print("    nothing here says anything about the canceller.")
    } else if leakWindows == 0 {
        print("    VERDICT: no window crossed the gate — on THIS machine, this")
        print("    arrangement would never self-barge.")
    } else {
        print("    VERDICT: \(leakWindows) window(s) crossed the gate — each one is a")
        print("    would-be self-barge onset. Compare the two arrangements:")
        print("    the shield's whole claim is that this number collapses.")
    }
}
