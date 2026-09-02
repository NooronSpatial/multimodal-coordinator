import Foundation
import KokoroSwift
import MLX

/// The Kokoro vendor, held behind one actor (4p, D-082).
///
/// `KokoroTTS` is a plain final class and `MLXArray` is not `Sendable`, so
/// neither may cross an isolation boundary. Both are BORN inside this
/// actor and never leave it; what leaves is `[Float]`, which is
/// `Sendable`. The token array `generateAudio` also returns is dropped
/// here for the same reason — this spike measures time, not timestamps.
///
/// Deliberately NOT `TTSDecoding`. That seam lives in `MultiModalKitTTS`,
/// in a package this project cannot link (the mlx-swift pin collision
/// recorded in `project.yml`). Conforming here would be a lie about how
/// close the two are.
actor KokoroEngine: SpikeMouth {
    nonisolated let name = "Kokoro-82M"

    /// MLX keeps its own peak counter, so Kokoro can report a vendor
    /// number as well as the shared footprint. TTSKit cannot, which is
    /// why the shared number is the footprint and not this.
    nonisolated var vendorPeakBytes: Int? { MLX.Memory.peakMemory }

    /// MLX's buffer cache, bounded (20 MB).
    ///
    /// NOT a tuning knob — the fix for the first field run, which spoke
    /// beautifully and was then killed. MLX keeps freed GPU buffers in a
    /// cache that grows without a limit, and eight decodes in a row grow
    /// it past what a phone will tolerate. This is the same value and the
    /// same reason as `LocalMind.cacheLimitBytes` in the library, whose
    /// comment already says it: an unbounded cache "drives a phone into
    /// jetsam".
    static let cacheLimitBytes = 20 * 1024 * 1024

    private var tts: KokoroTTS?
    private var voice: MLXArray?
    private(set) var precision: WeightPrecision = .float32

    /// `SpikeMouth`'s door: reload at whatever precision is currently
    /// selected. A default argument cannot satisfy a protocol
    /// requirement, and defaulting to fp32 here would silently undo a
    /// choice the person made on the screen.
    func load() throws { try load(precision: precision) }

    /// Loads the weights and one voice style. Both are files on disk;
    /// nothing here reaches the network.
    func load(precision: WeightPrecision) throws {
        // BEFORE the weights, not after: the limit must be in place for
        // the very first allocation the loader makes.
        MLX.Memory.cacheLimit = Self.cacheLimitBytes
        // DROP THE OLD MODEL FIRST. Switching precision with the previous
        // weights still held would measure both at once and blame the new
        // one — the reload is exactly when the peak is most fragile.
        tts = nil
        voice = nil
        MLX.Memory.clearCache()
        try precision.build()
        self.precision = precision
        // The vendor's `init` force-tries its own weight load, so a
        // corrupt file crashes rather than throws. The download side
        // checks the byte count, and `build()` writes through a
        // temporary name, for exactly that reason.
        let engine = KokoroTTS(modelPath: precision.location, g2p: .misaki)
        let arrays = try MLX.loadArrays(url: SpikeAssets.location(of: SpikeAssets.voice))
        guard let style = arrays.values.first else {
            throw SpikeFailure.voiceFileEmpty(SpikeAssets.voice.name)
        }
        tts = engine
        voice = style
    }

    func speak(_ text: String) throws -> (samples: [Float], sampleRate: Int) {
        guard let tts, let voice else { throw SpikeFailure.notLoaded }
        // `af_heart` is a US voice, so `.enUS`. The vendor picks the
        // language from the caller, never from the voice file.
        let (samples, _) = try tts.generateAudio(voice: voice, language: .enUS, text: text)
        // Returning the cache is housekeeping. It sits INSIDE the timed
        // region because the caller's stopwatch wraps `speak`, and the
        // alternative — exempting one vendor's cleanup — is the thumb on
        // the scale this shared harness exists to remove.
        MLX.Memory.clearCache()
        // The rate comes from the vendor, never from a constant here.
        return (samples, KokoroTTS.Constants.samplingRate)
    }
}

enum SpikeFailure: Error, CustomStringConvertible {
    case notLoaded
    case voiceFileEmpty(String)
    case downloadIncomplete(name: String, got: Int, expected: Int)

    var description: String {
        switch self {
        case .notLoaded:
            return "the model is not loaded yet"
        case .voiceFileEmpty(let name):
            return "\(name) held no arrays — the download is not a voice file"
        case .downloadIncomplete(let name, let got, let expected):
            return "\(name) arrived as \(got) bytes, expected \(expected) — not used"
        }
    }
}

extension Duration {
    /// Integer components first, so the microsecond figure is exact
    /// before it becomes a `Double` — the same conversion the library's
    /// `DecodeStep` uses.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds / 1_000_000_000) / 1_000_000
    }
}
