import Foundation
import MultiModalKit

/// Phase 2 live demo: microphone → ring → pump → transcription → terminal.
///
/// The [recogniser] listener from milestone 1c is no longer a stand-in: it is
/// a real `TranscriptionSession` running Apple's on-device engine. If the
/// speech model is missing, the demo offers the download and — if it fails,
/// as it repeatedly has on some networks — says so honestly and runs with
/// voice detection only. Failure is an event, not an excuse to crash.
///
/// Demo-only liberties (never taken in the library or its tests): a real
/// `ContinuousClock` drives the pump, and Foundation is imported for stdout
/// flushing. The library itself stays clock-injected.
@main
struct AudioDemo {
    static func main() async {
        setbuf(stdout, nil)

        // Engine selection: `swift run audio-demo [apple|whisper] [--talk]`.
        // Born of a real machine: this Mac's asset daemon refuses Apple's
        // model, so waiting through its failed download on every run was
        // pure ceremony — while Whisper sits installed and willing.
        // `--talk` adds the Phase 4a turn loop: a scripted echo reply,
        // "spoken" into the terminal — barge it mid-reply with your voice.
        let arguments = Array(CommandLine.arguments.dropFirst())
        let flags = DemoFlags(arguments: arguments)
        guard let ear = chosenEar(flags.choice) else { return }

        // The model phase comes FIRST — before the microphone exists.
        // Learned live: with the mic started first, a 15-minute failed
        // download left the ring honestly counting 43,206,464 dropped frames
        // (900 s × 48 kHz) that nobody was reading. The ring told the truth;
        // the ordering was the bug.
        let engineReady = await readyModel(ear.engine, named: flags.choice)

        // ~1 second of audio at 48 kHz; rounded up to a power of two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 48_000)

        let microphone = MicrophoneSource(voiceProcessing: flags.wantsAEC)
        do {
            try microphone.start(into: producer)
        } catch {
            print("Could not start the microphone: \(error.localizedDescription)")
            print("(macOS may be asking for permission — check the prompt, then run again.)")
            return
        }

        let sampleRate = microphone.sampleRate
        // Field forensics (the 08-13 --talk investigation): the demo was
        // BLIND to listener overflow — the pump's broadcast drops oldest
        // silently when a listener stalls (D-012), and the session's merged
        // loop can stall on inline stage awaits (a recorded 4a known limit).
        // Health makes the invisible number visible.
        let diagnostics = PipelineDiagnostics()
        let pump = makePump(reading: consumer, flags: flags,
                            sampleRate: sampleRate, diagnostics: diagnostics)

        let transcription: TranscriptionSession? = engineReady
            ? TranscriptionSession(
                engine: ear.engine,
                config: .init(format: .init(sampleRate: sampleRate, channels: 1)),
                diagnostics: diagnostics)
            : nil

        printBanner(flags, sampleRate: sampleRate,
                    engine: transcription == nil ? nil : ear.name,
                    voiceProcessingActive: microphone.voiceProcessingActive)

        if flags.levels {
            await runLevelProbe(reading: consumer, wantsAEC: flags.wantsAEC,
                                voiceProcessingActive: microphone.voiceProcessingActive)
            return
        }

        await runPipeline(pump: pump, transcription: transcription,
                          ringDrops: consumer, diagnostics: diagnostics, flags: flags)
    }
}
