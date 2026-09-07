import Foundation
import MultiModalKit

// Extends `AudioDemo` with what the FRONT DOOR needs from this machine:
// the policy numbers it earned (as one configuration), and the screen
// consumers that observe the session (as one function). The pump, the
// session, the coordinator, the listener order and the task group are the
// runtime's now (4t, D-093) — the hand-wiring that used to live here was
// deleted, not wrapped (AC-208).

extension AudioDemo {
    /// What this machine established before the door opened: the ear
    /// whose model is (or is not) ready, the ring's read side, and the
    /// rate the microphone actually runs at. Three facts from startup,
    /// carried as one thing because they ARE one thing.
    struct Machine {
        let ear: any TranscriptionEngine
        let consumer: AudioRingConsumer
        let sampleRate: Double
    }

    /// Every policy value this machine earned, passed through untouched
    /// (AC-204). The runtime adds none of its own.
    static func configuration(
        flags: DemoFlags, machine: Machine, screen: Screen,
        releaseSource: @escaping @Sendable () async -> Void
    ) -> AIRuntime<ContinuousClock>.Configuration {
        let sampleRate = machine.sampleRate
        let chunkFrames = Int(sampleRate * 0.02)          // 20 ms of sound per verdict
        return .init(
            consumer: machine.consumer,
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
            ear: machine.ear,
            // The Phase 4b slice (AC-84): with `--talk` the loop SPEAKS —
            // a real mind and mouth behind the same seams the scripted
            // organs proved. Without it, listen-only (F-3 = B): no mind,
            // no mouth, no coordinator.
            mind: flags.talk ? chosenMind(flags.arguments, screen: screen) : nil,
            mouth: flags.talk ? chosenMouth(flags.arguments) : nil,
            pump: .init(sampleRate: sampleRate, pollInterval: .milliseconds(10),
                        chunkFrames: chunkFrames, preRollChunks: 10),
            transcription: .init(format: .init(sampleRate: sampleRate, channels: 1)),
            // `--gate <ms>`: the AC-81 reply gate, this machine's to earn.
            turns: .init(replyGate: .milliseconds(Int(flags.gateMs))),
            clock: ContinuousClock(),
            // Field forensics (the 08-13 --talk investigation): the demo
            // was BLIND to listener overflow — the pump's broadcast drops
            // oldest silently when a listener stalls (D-012). Health makes
            // the invisible number visible.
            diagnostics: PipelineDiagnostics(),
            latencyReporter: ConsoleLatency(screen: screen),
            // Nothing this app holds renders: the neural mouth, when
            // chosen, owns its own engine. Step 2 of the teardown is
            // therefore absent here and present on the phone.
            stopRendering: nil,
            releaseSource: releaseSource)
    }

    /// The screen, observing the session: health, per-utterance audio
    /// forensics, transcripts, and (with `--talk`) the turns. One nested
    /// group; when the runtime stops its actors every stream here ends
    /// and this returns — nothing outlives the conversation.
    static func observe(
        _ session: AIRuntime<ContinuousClock>.Session, on screen: Screen,
        ringDrops consumer: AudioRingConsumer
    ) async {
        await withTaskGroup(of: Void.self) { group in
            if let health = session.health {
                group.addTask { await showHealth(health.events, on: screen) }
            }
            group.addTask {
                await showAudio(session.audio.events, on: screen, ringDrops: consumer)
            }
            group.addTask { await showTranscripts(session.transcripts.events, on: screen) }
            if let turns = session.turns {
                group.addTask { await showTurns(turns.events, on: screen) }
            }
        }
    }
}
