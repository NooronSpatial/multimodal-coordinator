// The `voice-onmic` instrument: the neural voice rendered onto a LIVE
// capture engine — the phone's own path, on hardware I can watch.
import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitTTS

// `swift run bakeoff voice-onmic` — THE COMBINATION NOTHING HAS EVER
// TESTED, and the one the iPhone keeps failing on.
//
// Every neural measurement so far rendered onto an engine the mouth
// owned. The phone renders onto the CAPTURE engine — a live
// AVAudioEngine with a voice-processing input unit and a microphone tap
// already running — and that path has produced five faults in one field
// session while never once being exercised on a machine I control.
//
// This Mac has a microphone and voice processing. So it can run exactly
// that path, here, instead of costing Ryad another rebuild.
@MainActor
func runVoiceOnMic(_ arguments: [String]) async throws {
    print("\n🎤  NEURAL VOICE ON A LIVE CAPTURE ENGINE (AC-104's Mac rehearsal)")
    print("    the path the phone runs, on hardware I can watch\n")

    // THE ONE VARIABLE UNDER TEST. `--no-output-chain` builds capture
    // exactly as it was before AC-108 touched it, so the two runs differ
    // in one line and the comparison means something.
    let wantsOutputChain = !arguments.contains("--no-output-chain")
    print("    output chain: \(wantsOutputChain ? "YES (the neural path)" : "no (the pre-AC-108 path)")")
    let (producer, _) = AudioRing.create(minimumCapacity: 48_000)
    let microphone = MicrophoneSource(voiceProcessing: true,
                                      hostsPlayback: wantsOutputChain)
    do {
        try microphone.start(into: producer)
    } catch {
        print("❌ capture would not start: \(error)")
        exit(1)
    }
    print("    capture running: \(microphone.isRunning), "
          + "engine: \(microphone.engineIsRunning), "
          + "voice processing: \(microphone.voiceProcessingActive)")
    print("    input rate: \(Int(microphone.sampleRate)) Hz")

    let voice = NeuralVoice(renderingOn: microphone.playbackHost)
    guard await voice.modelInstalled() else {
        print("❌ the neural model is not installed")
        microphone.stop(); exit(1)
    }
    do { try await voice.ensureModel() } catch { print("❌ load failed: \(error)"); microphone.stop(); exit(1) }

    onMicReport("before speaking", microphone)

    try await onMicSpeak(voice: voice, microphone: microphone)

    microphone.stop()
    print("\n    after stop: engine \(microphone.engineIsRunning ? "running" : "stopped")"
          + " · reconfigs \(microphone.configurationChanges)")
    print("\n  READ IT AS: started NO means the reply never became audible —")
    print("  the same silence the phone shows. reconfigs above 0 means the")
    print("  engine tore its own graph down, which is the phone's vanishing")
    print("  microphone indicator. Neither can be blamed on the model.")
    exit(0)
}

// The host's rate, read back AFTER an attach — 0 means nothing ever
// rendered, which is itself the answer.
@MainActor
private func onMicReport(_ label: String, _ microphone: MicrophoneSource) {
    print("    \(label): engine \(microphone.engineIsRunning ? "running" : "STOPPED")"
          + " · reconfigs \(microphone.configurationChanges)"
          + " · host rate \(Int(microphone.playbackHost.outputSampleRate))"
          + " · hosted \(microphone.playbackHost.hostedCount)")
}

@MainActor
private func onMicSpeak(voice: NeuralVoice, microphone: MicrophoneSource) async throws {
    for attempt in 1...2 {
        print("\n  utterance \(attempt):")
        let run = try await voice.openUtterance()
        let clock = ContinuousClock()
        let t0 = clock.now
        var sawStarted = false
        var sawFinished = false
        var failure: String?

        let feeder = Task {
            await run.feed("Testing the neural voice on the capture engine.")
            await run.finishTokens()
        }
        for await update in run.updates {
            switch update {
            case .started: sawStarted = true
            case .finished: sawFinished = true
            case .failed(let why): failure = why
            }
        }
        await feeder.value
        let elapsed = t0.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) * 1e-15
        print(String(format: "    started %@ · finished %@ · %.0f ms%@",
                     sawStarted ? "YES" : "NO", sawFinished ? "YES" : "NO", ms,
                     failure.map { " · FAILED: \($0)" } ?? ""))
        onMicReport("    after", microphone)
    }
}
