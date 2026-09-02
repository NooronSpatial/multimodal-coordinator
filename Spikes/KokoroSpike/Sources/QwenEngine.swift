import Foundation
import Synchronization
import TTSKit

/// The mouth this project already ships, in the same harness as the
/// challenger (4p, Ryad's ruling after the first Kokoro numbers).
///
/// **Why this type exists.** Kokoro's 0.19–0.21 was measured bare: no
/// microphone, no phraser, no mind, no audio graph. Qwen3's 1.21 was
/// measured inside the live app with the mind feeding it. Six times is a
/// large gap, and part of it could have been the harness rather than the
/// model. Now both mouths run the same sentences, through the same
/// stopwatch, in the same process, back to back.
///
/// **The pin collision does not reach here.** `argmax-oss-swift` depends
/// on swift-argument-parser, vapor and swift-openapi — never mlx-swift.
/// TTSKit is CoreML, so it can sit beside KokoroSwift in this project
/// even though the Qwen MIND cannot.
///
/// This deliberately mirrors `TTSKitDecoder` and `NeuralVoice` in the
/// library rather than inventing its own configuration. A spike that
/// measured a configuration the app never runs would measure a stranger.
actor QwenEngine: SpikeMouth {
    nonisolated let name = "Qwen3-TTS 0.6B"

    private var kit: TTSKit?

    /// TTSKit fetches its own weights (~1 GB) into THIS app's container.
    /// The demo app's copy cannot be shared — a different container is a
    /// different app — so the first load here downloads again.
    ///
    /// The configuration is `VoiceLevers.phoneDefault`, character for
    /// character: `.stepped` because `.fused` does not load on iOS 18+,
    /// and `.throughputOptimized` because D-071 ruled it on this very
    /// phone. Anything else would measure a mouth the app does not run.
    func load() async throws {
        let kit = try await TTSKit(TTSKitConfig(
            model: .qwen3TTS_0_6b,
            speechDecoderMode: .throughputOptimized,
            multiCodeDecoderMode: .stepped,
            download: true, load: true, seed: nil))
        self.kit = kit
    }

    func speak(_ text: String) async throws -> (samples: [Float], sampleRate: Int) {
        guard let kit else { throw SpikeFailure.notLoaded }
        var options = GenerationOptions()
        // THE CORRECTNESS PIN, copied from `TTSKitDecoder` with its
        // reason. The default is 0 — "all chunks run concurrently in one
        // batch" — and on that path the streaming callback receives
        // `audio: []` on every step, with the real samples arriving only
        // after the WHOLE batch finishes. `1` takes the sequential
        // branch, which passes the callback through untouched. The
        // library's own real-time path sets the same value.
        //
        // It matters MORE here than in the library, not less: this spike
        // accumulates the callback's samples to measure audio length, and
        // on the batched path it would accumulate nothing and then divide
        // by zero audio.
        options.concurrentWorkerCount = 1
        // `voice`, `language` and temperature stay at the model's own
        // defaults — the same choice `NeuralVoice` makes, and the same
        // one Kokoro gets here.
        // The callback is `@Sendable` and TTSKit may call it from its
        // own queue, so the accumulator is behind a `Mutex` — the house
        // proof holds: nothing suspends while it is held, and no
        // continuation is resumed under it.
        let collected = Mutex<[Float]>([])
        _ = try await kit.generate(
            text: text, voice: nil, language: nil, options: options
        ) { progress in
            collected.withLock { $0.append(contentsOf: progress.audio) }
            return true          // TTSKit reads true as "keep going"
        }
        // Straight from the loaded speech decoder — 24 kHz for Qwen3, but
        // asked rather than assumed.
        return (collected.withLock { $0 }, kit.sampleRate)
    }
}
