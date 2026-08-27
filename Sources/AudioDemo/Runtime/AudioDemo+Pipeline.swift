import Foundation
import MultiModalKit

// Extends `AudioDemo` with the live pipeline: building the pump from the
// levers, and running every listener — screen, health, transcripts and
// (with `--talk`) the turn loop — in one task group.

extension AudioDemo {
    /// The pump, wired to this machine's earned numbers.
    static func makePump(
        reading consumer: AudioRingConsumer, flags: DemoFlags,
        sampleRate: Double, diagnostics: PipelineDiagnostics
    ) -> AudioPump<ContinuousClock> {
        let chunkFrames = Int(sampleRate * 0.02)          // 20 ms of sound per verdict
        return AudioPump(
            consumer: consumer,
            // 0.02 is the LAPTOP gate. The 0.01 borrowed from the iPhone
            // tuning flaps on a Mac's ambient: field run 08-13 showed the
            // post-sentence level hovering AT 0.01 — the gate opened every
            // 0.84 s like a metronome, one empty Whisper decode per tick.
            // The iPhone demo keeps 0.01; each machine earns its own number.
            // The onset window (D-035) ships OFF here — ruled D-036 after
            // the field A/B clipped word onsets twice ("Riyat", "rate")
            // for zero quiet-room benefit. The gate is this machine's
            // earned defense; `--onset <ms>` re-arms the window for
            // experiments (wire pre-roll ≥ the window per the F-4 law).
            vad: EnergyVAD(config: .init(threshold: flags.vadThreshold,
                                         hangoverFrames: Int(sampleRate * flags.hangoverMs / 1000),
                                         onsetFrames: Int(sampleRate * flags.onsetMs / 1000))),
            clock: ContinuousClock(),
            config: .init(sampleRate: sampleRate, pollInterval: .milliseconds(10),
                          chunkFrames: chunkFrames, preRollChunks: 10),
            diagnostics: diagnostics)
    }

    /// Every listener, running until the process is killed.
    static func runPipeline(
        pump: AudioPump<ContinuousClock>, transcription: TranscriptionSession?,
        ringDrops consumer: AudioRingConsumer, diagnostics: PipelineDiagnostics,
        flags: DemoFlags
    ) async {
        let screen = Screen()

        await withTaskGroup(of: Void.self) { group in
            let audioForScreen = await pump.listen()
            let health = diagnostics.health()          // listen BEFORE run: no replay
            group.addTask { await diagnostics.run() }
            group.addTask { await showHealth(health.events, on: screen) }
            group.addTask { await pump.run() }
            group.addTask {
                await showAudio(audioForScreen.events, on: screen, ringDrops: consumer)
            }

            if let transcription {
                let audioForSession = await pump.listen()
                let transcripts = await transcription.listen()
                group.addTask { await transcription.run(events: audioForSession.events) }
                group.addTask { await showTranscripts(transcripts.events, on: screen) }

                if flags.talk {
                    // The Phase 4b slice (AC-84): the loop now SPEAKS —
                    // AVSpeechSynthesizer behind the same seam the scripted
                    // voice proved. Real microphone barge-in, the R2 latency
                    // seam on a real clock, and (--gate) the AC-81 reply
                    // gate: the demo reuses the exact code paths the
                    // deterministic tests prove.
                    let coordinator = TurnCoordinator(
                        replyGenerator: chosenMind(flags.arguments, screen: screen),
                        synthesizer: chosenMouth(flags.arguments),
                        config: .init(replyGate: .milliseconds(Int(flags.gateMs))),
                        clock: ContinuousClock(),
                        latencyReporter: ConsoleLatency(screen: screen))
                    let audioForTurns = await pump.listen()
                    let transcriptsForTurns = await transcription.listen()
                    let turnEvents = await coordinator.listen()
                    group.addTask {
                        await coordinator.run(
                            audio: audioForTurns.events,
                            transcripts: transcriptsForTurns.events)
                    }
                    group.addTask { await showTurns(turnEvents.events, on: screen) }
                }
            }
        }
    }
}
