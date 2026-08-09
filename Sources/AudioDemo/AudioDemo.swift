import Foundation
import MultiModalKit

/// Milestone 1c live demo: microphone → lock-free ring → pump → speech events.
///
/// Speak, and watch it decide. The bar is the loudness of the chunk being
/// judged right now; the lines above it are the events the pump published.
/// Two listeners are attached on purpose — the display, and a stand-in for a
/// speech recogniser — to show that both see the same sequence independently.
///
/// Demo-only liberties (never taken in the library or its tests): a real
/// `ContinuousClock` drives the pump, and Foundation is imported for stdout
/// flushing and number formatting. The library itself stays clock-injected.
@main
struct AudioDemo {
    static func main() async {
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
        let hangoverFrames = Int(sampleRate * 0.3)        // 300 ms of quiet ends a phrase

        let pump = AudioPump(
            consumer: consumer,
            vad: EnergyVAD(config: .init(threshold: 0.02, hangoverFrames: hangoverFrames)),
            clock: ContinuousClock(),
            config: .init(
                sampleRate: sampleRate,
                pollInterval: .milliseconds(10),
                chunkFrames: chunkFrames,
                preRollChunks: 2
            )
        )

        let display = await pump.listen()
        let recogniser = await pump.listen()

        print("🎙  Speak — the pump is listening.  (Ctrl-C to quit)")
        print("    \(Int(sampleRate)) Hz · \(chunkFrames)-frame chunks (20 ms) · 300 ms hangover · 2 chunks of pre-roll")
        print("    two listeners attached: [display] and [recogniser]\n")
        fflush(stdout)                                    // so the header shows even when piped

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.run() }
            group.addTask { await showEvents(display.events, ringDrops: consumer) }
            group.addTask { await pretendToTranscribe(recogniser.events) }
        }
    }

    /// Listener 1 — the picture on screen.
    static func showEvents(_ events: AsyncStream<AudioEvent>, ringDrops consumer: AudioRingConsumer) async {
        var chunksThisPhrase = 0

        for await event in events {
            switch event {
            case .speechStarted(let at):
                chunksThisPhrase = 0
                line("▶︎  speech started  at \(seconds(at))")

            case .audioSegment(let chunk):
                chunksThisPhrase += 1
                status(bar(for: chunk), "speaking · \(chunksThisPhrase) chunks · ring drops: \(consumer.totalDropped)")

            case .speechEnded(let at):
                let spoken = Double(chunksThisPhrase) * 0.02
                line("⏹  speech ended    at \(seconds(at))  —  \(format(spoken)) s of audio in \(chunksThisPhrase) chunks")
                status(String(repeating: "·", count: 40), "listening…")

            case .dropped(let frames, let at):
                line("⚠️  dropped \(frames) frames at \(seconds(at))  — the machine fell behind, and says so")
            }
        }
    }

    /// Listener 2 — where a speech recogniser would sit. It only counts, but
    /// it proves the point: the same events arrive here, independently.
    static func pretendToTranscribe(_ events: AsyncStream<AudioEvent>) async {
        var utterances = 0
        var frames = 0

        for await event in events {
            switch event {
            case .audioSegment(let chunk):
                frames += chunk.frameCount
            case .speechEnded:
                utterances += 1
                line("   ↳ [recogniser] utterance #\(utterances) complete — \(frames) frames received so far")
            default:
                break
            }
        }
    }

    // MARK: - terminal helpers

    /// A permanent line, printed above the status line.
    static func line(_ text: String) {
        print("\r\u{1B}[K\(text)")
        fflush(stdout)
    }

    /// The single line that keeps being rewritten in place.
    static func status(_ bar: String, _ text: String) {
        print("\r\u{1B}[K[\(bar)] \(text)", terminator: "")
        fflush(stdout)
    }

    static func bar(for chunk: AudioChunk) -> String {
        var sumOfSquares: Float = 0
        for sample in chunk.samples { sumOfSquares += sample * sample }
        let rms = (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()

        let width = 40
        let level = min(Int(rms * 300), width)
        return String(repeating: "█", count: level) + String(repeating: "·", count: width - level)
    }

    static func seconds(_ time: AudioTime) -> String { format(time.seconds) + " s" }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
