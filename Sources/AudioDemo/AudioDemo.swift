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

        // `nonisolated(unsafe)`, with the proof the house demands for any
        // island (§4.1): `MicrophoneSource` is not `Sendable`, and it is
        // touched from exactly two places — `start(into:)` here, on this
        // task, before the runtime exists; and `stop()` inside
        // `releaseSource`, which the runtime calls ONCE, after every loop
        // has drained (AC-203). The two can never overlap.
        nonisolated(unsafe) let microphone = MicrophoneSource(voiceProcessing: flags.wantsAEC)
        do {
            try microphone.start(into: producer)
        } catch {
            print("Could not start the microphone: \(error.localizedDescription)")
            print("(macOS may be asking for permission — check the prompt, then run again.)")
            return
        }

        let sampleRate = microphone.sampleRate

        printBanner(flags, sampleRate: sampleRate,
                    engine: engineReady ? ear.name : nil,
                    voiceProcessingActive: microphone.voiceProcessingActive)

        if flags.levels {
            await runLevelProbe(reading: consumer, wantsAEC: flags.wantsAEC,
                                voiceProcessingActive: microphone.voiceProcessingActive)
            return
        }

        // THE FRONT DOOR (4t). What used to be assembled here by hand —
        // pump, session, coordinator, the listener order, the task group —
        // is the runtime's. What stays here is every POLICY number this
        // machine earned, passed in and visible (AC-204).
        //
        // An ear whose model is not ready is passed in all the same. It
        // used to mean "voice detection only"; now every utterance reports
        // its transcription failure on screen instead — failure is an
        // event (AC-65), which is the library's own rule finally applied
        // to its own demo.
        let screen = Screen()
        let runtime: AIRuntime<ContinuousClock>
        do {
            runtime = try AIRuntime(configuration(
                flags: flags,
                machine: Machine(ear: ear.engine, consumer: consumer, sampleRate: sampleRate),
                screen: screen,
                releaseSource: { microphone.stop() }))
        } catch {
            // The door refused the organs (AC-241): a mind without a mouth
            // or the reverse. This demo pairs them from one flag, so the
            // path is a safety net — but the microphone is already
            // capturing, and a net that leaks a source is not a net.
            print("Could not assemble the runtime: \(error)")
            microphone.stop()
            return
        }
        let pipeline = Task {
            await runtime.run { session in
                await observe(session, on: screen, ringDrops: consumer)
            }
        }

        // Ctrl-C CANCELS rather than kills (AC-207). Before the runtime,
        // this demo ended by the process dying, so its microphone was
        // never released and no teardown order existed for it to get
        // wrong. Now the same three steps the phone learned the hard way
        // run here too — which is the whole argument for a front door: a
        // second caller inherits the rule instead of re-learning it.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { pipeline.cancel() }
        interrupt.resume()
        await pipeline.value
        print("\n(released the microphone — teardown ran in order)")
    }
}
