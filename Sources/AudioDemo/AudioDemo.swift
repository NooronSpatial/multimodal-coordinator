import Foundation
import MultiModalKit

/// Milestone 1b live demo: microphone → lock-free ring → level meter.
///
/// Speak, and watch the bar move. The number on the right is the ring's
/// honest drop counter — on a healthy run it stays at 0.
///
/// Demo-only liberties (never taken in the library or its tests): a real
/// `Task.sleep` paces the read loop, and Foundation is imported for stdout
/// flushing. The library itself stays clock-injected and Foundation-free.
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

        print("🎙  Live input level — speak! (Ctrl-C to quit)")
        print("    sample rate: \(Int(microphone.sampleRate)) Hz\n")

        var bucket = [Float](repeating: 0, count: 4800)   // reused forever — zero allocations in the loop
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            let result = bucket.withUnsafeMutableBufferPointer { consumer.read(into: $0) }
            guard result.framesRead > 0 else { continue }

            var sumOfSquares: Float = 0
            for i in 0..<result.framesRead {
                let sample = bucket[i]
                sumOfSquares += sample * sample
            }
            let rms = (sumOfSquares / Float(result.framesRead)).squareRoot()

            let width = 50
            let level = min(Int(rms * 300), width)
            let bar = String(repeating: "█", count: level)
                    + String(repeating: "·", count: width - level)
            print("\r[\(bar)] dropped: \(consumer.totalDropped)   ", terminator: "")
            fflush(stdout)
        }
    }
}
