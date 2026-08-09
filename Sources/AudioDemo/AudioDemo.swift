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

        // The model phase comes FIRST — before the microphone exists.
        // Learned live: with the mic started first, a 15-minute failed
        // download left the ring honestly counting 43,206,464 dropped frames
        // (900 s × 48 kHz) that nobody was reading. The ring told the truth;
        // the ordering was the bug.
        let engine = AppleSpeechEngine()
        var engineReady = await engine.modelInstalled()
        if !engineReady {
            print("⏬ The en-US speech model is not on this Mac — downloading")
            print("   (system-managed; known to fail on some machines — the demo degrades honestly)…")
            do {
                try await engine.ensureModel()
                print("✅ model installed")
                engineReady = true
            } catch {
                print("⚠️  download failed: \(error)")
                print("   Running with voice detection only — transcription disabled.")
            }
        }

        // ~1 second of audio at 48 kHz; rounded up to a power of two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 48_000)

        let microphone = MicrophoneSource()
        do {
            try microphone.start(into: producer)
        } catch {
            print("Could not start the microphone: \(error.localizedDescription)")
            print("(macOS may be asking for permission — check the prompt, then run again.)")
            return
        }

        let sampleRate = microphone.sampleRate
        let chunkFrames = Int(sampleRate * 0.02)          // 20 ms of sound per verdict
        let pump = AudioPump(
            consumer: consumer,
            // Field-tuned values from the iOS run (0.01 gate, 200 ms pre-roll).
            vad: EnergyVAD(config: .init(threshold: 0.01,
                                         hangoverFrames: Int(sampleRate * 0.3))),
            clock: ContinuousClock(),
            config: .init(sampleRate: sampleRate, pollInterval: .milliseconds(10),
                          chunkFrames: chunkFrames, preRollChunks: 10))

        let transcription: TranscriptionSession? = engineReady
            ? TranscriptionSession(
                engine: engine,
                config: .init(format: .init(sampleRate: sampleRate, channels: 1)))
            : nil

        print("\n🎙  Speak — the pump is listening.  (Ctrl-C to quit)")
        print("    \(Int(sampleRate)) Hz · 20 ms chunks · 300 ms hangover · 200 ms pre-roll")
        print("    transcription: \(transcription == nil ? "OFF (no model)" : "on-device, en-US")\n")

        let screen = Screen()

        await withTaskGroup(of: Void.self) { group in
            let audioForScreen = await pump.listen()
            group.addTask { await pump.run() }
            group.addTask {
                await showAudio(audioForScreen.events, on: screen, ringDrops: consumer)
            }

            if let transcription {
                let audioForSession = await pump.listen()
                let transcripts = await transcription.listen()
                group.addTask { await transcription.run(events: audioForSession.events) }
                group.addTask { await showTranscripts(transcripts.events, on: screen) }
            }
        }
    }

    // MARK: - the two listeners' views of the world

    static func showAudio(
        _ events: AsyncStream<AudioEvent>, on screen: Screen, ringDrops consumer: AudioRingConsumer
    ) async {
        for await event in events {
            switch event {
            case .speechStarted:
                await screen.set(speaking: true)
            case .audioSegment(let chunk):
                await screen.set(level: level(of: chunk), drops: consumer.totalDropped)
            case .speechEnded:
                await screen.set(speaking: false)
            case .dropped(let frames, let at):
                await screen.log("⚠️  dropped \(frames) frames at \(format(at.seconds)) s")
            }
        }
    }

    static func showTranscripts(_ events: AsyncStream<TranscriptEvent>, on screen: Screen) async {
        for await event in events {
            switch event {
            case .partial(let text, _, _):
                await screen.set(partial: text)
            case .final(let text, let utterance, let at):
                await screen.log("💬 [\(utterance)] \(text)   (\(format(at.seconds)) s)")
                await screen.set(partial: "")
            case .failed(let failure, let utterance, _):
                await screen.log("⚠️  [\(utterance)] recognition failed: \(failure)")
                await screen.set(partial: "")
            case .truncated(let utterance, _):
                await screen.log("✂️  [\(utterance)] utterance hit the 30 s ceiling")
            }
        }
    }

    static func level(of chunk: AudioChunk) -> Int {
        var sumOfSquares: Float = 0
        for sample in chunk.samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()
        return min(Int(rms * 300), 24)
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// One owner for the terminal: permanent lines above, one live status line
/// below (level bar + the current partial). Two event streams write here
/// concurrently; the actor serializes them so the screen never tears.
actor Screen {
    private var speaking = false
    private var levelBar = ""
    private var partial = ""
    private var drops = 0

    func set(speaking: Bool) {
        self.speaking = speaking
        if !speaking { levelBar = "" }
        render()
    }

    func set(level: Int, drops: Int) {
        self.levelBar = String(repeating: "█", count: level)
        self.drops = drops
        render()
    }

    func set(partial: String) {
        self.partial = partial
        render()
    }

    func log(_ line: String) {
        print("\r\u{1B}[K\(line)")
        render()
    }

    private func render() {
        let icon = speaking ? "🗣" : "…"
        let text = partial.isEmpty ? "" : "  \(partial.suffix(48))"
        let dropText = drops > 0 ? "  dropped:\(drops)" : ""
        print("\r\u{1B}[K\(icon) [\(levelBar.padding(toLength: 24, withPad: "·", startingAt: 0))]\(text)\(dropText)",
              terminator: "")
    }
}
