import KokoroSwift
import MLX

/// THE SECOND REAL DECODER — and the only place KokoroSwift's API is
/// named (4q, D-084; the seam is D-053 F-6's, finally paying for itself).
///
/// `TTSKitDecoder`'s doc comment promised that replacing the vendor would
/// cost "one more conformance of `TTSDecoding`". This file is that promise
/// being collected. Everything Kokoro brought with it stops here:
/// `KokoroTTS`, `MLXArray`, `Language`, `G2P`.
///
/// ## An actor, where the other decoder is a struct
///
/// Not a style difference — a Sendability one, and the reason is worth
/// knowing. `TTSKit` is `open class … @unchecked Sendable`, so a struct
/// holding it needs no unsafety of its own. `KokoroTTS` is a plain
/// `final class` and `MLXArray` is not `Sendable` at all, so neither may
/// cross an isolation boundary. Both are BORN inside this actor and never
/// leave it; what leaves is `[Float]`.
///
/// The alternative — `@unchecked Sendable` with a `Mutex` — would hold a
/// lock across a multi-second decode and call `onStep` underneath it,
/// which is the house's rule about locks pointed straight at its own foot.
///
/// ## The one-shot shape, and what it costs
///
/// Kokoro is StyleTTS 2: not autoregressive, so a phrase arrives whole.
/// `onStep` is therefore called **exactly once**, and the seam's contract
/// — *"return false to stop the decode at its next step"* — has no next
/// step to stop. AC-181 pins that limit with a scripted decoder: the
/// answer is recorded and ignored, the compute is not saved, and
/// **correctness is untouched** because the run re-checks its ticket
/// before it schedules anything. Cancellation is the optimisation; the
/// ticket is the guarantee.
///
/// The cost is bounded by phrase length, which is why the mouth above
/// caps it: §55 measured ~120 MB of transient memory per second of audio
/// on top of ~336 MB fixed, so an uncapped phrase is an uncapped
/// allocation.
actor KokoroDecoder: TTSDecoding {
    /// Kokoro's own rate, asked of the vendor rather than written here.
    ///
    /// It is a vendor CONSTANT rather than a property of the loaded model,
    /// which is the one way this differs from `TTSKitDecoder.sampleRate`
    /// — Kokoro has a single rate and exposes it statically. Still not a
    /// literal in our code: a decoder and a format that disagree is the
    /// fault the field heard as a voice "speaking in weird way like
    /// someone drunk", 24 kHz played as 16 kHz.
    nonisolated var sampleRate: Int { KokoroTTS.Constants.samplingRate }

    private let engine: KokoroTTS
    private let voice: MLXArray

    /// Loads the weights and one voice style from files already on disk.
    /// Nothing here reaches the network — that is `KokoroWeights.ensure`,
    /// and keeping them apart is `ModelBacked`'s doctrine (D-078).
    ///
    /// MLX's buffer cache is bounded BEFORE the first allocation the
    /// loader makes. Not a tuning knob: the 4p field run spoke perfectly
    /// and was then killed, because MLX keeps freed GPU buffers in a cache
    /// that grows without a limit. The same value and the same reason as
    /// `LocalMind.cacheLimitBytes`, whose comment already says it drives a
    /// phone into jetsam.
    init(weights: KokoroWeights, cacheLimitBytes: Int = 20 * 1024 * 1024) throws {
        MLX.Memory.cacheLimit = cacheLimitBytes
        let arrays = try MLX.loadArrays(url: weights.voiceFile)
        guard let style = arrays.values.first else {
            throw KokoroWeightsFailure.voiceFileEmpty(weights.voiceFile.lastPathComponent)
        }
        // The vendor force-tries its own weight load, so a corrupt file
        // crashes rather than throws. `KokoroWeights` checks byte counts
        // and writes casts through a temporary name for exactly that.
        self.engine = KokoroTTS(modelPath: weights.modelFile, g2p: .misaki)
        self.voice = style
    }

    func decode(_ text: String,
                temperature: Float?,
                onStep: @escaping @Sendable ([Float]) -> Bool) async throws {
        // TEMPERATURE IS NOT A LEVER HERE, and silence about that would be
        // a lie by omission. `generateAudio` takes `speed`, not
        // temperature: StyleTTS 2 has no sampling temperature to turn.
        // The parameter is accepted because the seam is shared and
        // ignored because this vendor has nothing to do with it.
        _ = temperature
        // `af_heart` is a US voice. The language comes from the caller,
        // never from the voice file — the vendor does not infer it.
        let (samples, _) = try engine.generateAudio(voice: voice, language: .enUS, text: text)
        // ONE CALL. The whole phrase, once. The answer is recorded by the
        // run and cannot be acted on: see the one-shot note above.
        _ = onStep(samples)
        // Housekeeping, after the samples are handed over and never
        // before: a caller timing this decode is timing Kokoro, not our
        // tidying.
        MLX.Memory.clearCache()
    }
}
