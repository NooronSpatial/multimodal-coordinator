// How the bake-off CAPTURES what a mouth actually says: a tap on our own
// mixer, Apple's offline `write` path, and the seeded order a blind
// listening test needs. The voice-wer instrument is the caller.
import AVFoundation
import Foundation
import Synchronization

/// A tiny seeded generator, so the blind order is REPRODUCIBLE. The seed
/// is printed with the result: a listening test nobody can re-run is an
/// anecdote, and this repo does not record anecdotes as data.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}

/// CAPTURING WHAT THE MOUTH ACTUALLY SAYS (AC-103, the objective half).
///
/// A tap on the engine's mixer, which is deliberately the LAST point
/// before the speaker: it catches the audio including our own rendering,
/// resampling and buffering, which is what a listener would really hear.
/// Capturing the model's raw 24 kHz PCM instead would flatter us by
/// measuring the decoder rather than the pipeline.
///
/// `@unchecked Sendable` with the usual proof: one `Mutex` owns every
/// mutable byte, the tap closure only appends under it, and nothing
/// suspends while it is held.
final class MixerCapture: @unchecked Sendable {
    private let collected = Mutex<(samples: [Float], rate: Double)>(([], 0))
    private let engine: AVAudioEngine

    /// THE ENGINE IS NOT STARTED HERE, and that is the whole lesson of
    /// this type. The first version called `prepare()` and `start()` in
    /// this initialiser, before any player node existed. An engine
    /// started with no source node never pulls, so the player attached
    /// afterwards never rendered — and because the buffers are now
    /// scheduled with `.dataPlayedBack`, their completions correctly
    /// never fired and the whole tool hung at 0% CPU.
    ///
    /// The old `.dataConsumed` callback would have reported those
    /// buffers "done" and produced a table of silence. The hang was the
    /// honest failure of a more honest callback.
    ///
    /// So: `NeuralVoiceRun` starts the engine, with its player already
    /// attached, and the tap goes on afterwards.
    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// The capture's true rate, learned from the first buffer rather
    /// than asked of a node that may not be configured yet.
    var sampleRate: Double { collected.withLock { $0.rate } }

    func record() {
        collected.withLock { $0 = ([], 0) }
        // `self`, not the Mutex: a Mutex is non-copyable, so a capture
        // list would try to consume it out of the object that owns it.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] buffer, _ in
            guard let channel = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            // Channel 0 only: the source is mono, so the mixer's second
            // channel is a copy and averaging would buy nothing.
            let slice = Array(UnsafeBufferPointer(start: channel[0], count: frames))
            collected.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = buffer.format.sampleRate
            }
        }
    }

    func stop() -> [Float] {
        engine.mainMixerNode.removeTap(onBus: 0)
        return collected.withLock { $0.samples }
    }
}

/// The three values `captureApple`'s callback must guard together — a
/// named struct rather than a tuple, so each field reads as itself.
private struct AppleWriteState: Sendable {
    var samples: [Float] = []
    var rate: Double = 0
    var resumed = false
}

/// Apple's mouth does NOT render through our engine, so the tap cannot
/// see it. `write` is the framework's own offline path — same synthesis,
/// no speaker. Stated as a caveat wherever its numbers appear: it is not
/// the identical code path we ship, though it is the identical voice.
func captureApple(_ text: String) async -> (samples: [Float], sampleRate: Double)? {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    // One lock over everything mutable, `resumed` included: the callback
    // arrives on the framework's thread, and a plain `var` flag read and
    // written from there is a race that would eventually resume a
    // continuation twice — which traps.
    let box = Mutex(AppleWriteState())

    let result: (samples: [Float], sampleRate: Double)? = await withCheckedContinuation { continuation in
        synthesizer.write(utterance) { buffer in
            // `synthesizer` is touched HERE ON PURPOSE. Nothing else
            // retains it once this function's frame is gone, and a
            // deallocated synthesizer simply never calls back — the
            // continuation then waits forever. That is precisely how
            // this tool hung the first time it ran, at 0% CPU on
            // sentence 1, and `withExtendedLifetime` below is the belt
            // to this closure's braces.
            _ = synthesizer
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                let finished: (samples: [Float], sampleRate: Double)?? = box.withLock {
                    guard !$0.resumed else { return .none }
                    $0.resumed = true
                    return .some($0.samples.isEmpty ? nil : ($0.samples, $0.rate))
                }
                if let finished { continuation.resume(returning: finished) }
                return
            }
            guard let channel = pcm.floatChannelData else { return }
            let slice = Array(UnsafeBufferPointer(start: channel[0],
                                                  count: Int(pcm.frameLength)))
            box.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = pcm.format.sampleRate
            }
        }
    }
    withExtendedLifetime(synthesizer) {}
    return result
}
