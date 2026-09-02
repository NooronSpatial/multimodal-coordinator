import Foundation
import KokoroSwift
import MLX

/// The vendor, held behind one actor (4p, D-082).
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
actor KokoroEngine {
    /// What one decode cost. Wall time is measured around
    /// `generateAudio` alone — no download, no model load, no playback.
    struct Measurement: Sendable {
        let wallMilliseconds: Double
        let audioMilliseconds: Double
        /// MLX's live tensor memory after the decode, and the highest it
        /// has ever been in this process. Added after the first field run
        /// died on memory: a spike that measures speed and cannot say how
        /// close it came to jetsam is measuring half the question
        /// (AC-185).
        let activeBytes: Int
        let peakBytes: Int
        /// This project's convention, stated because the vendor's README
        /// uses the reciprocal: **wall ÷ audio**, so lower is better and
        /// 1.0 is exactly real time. The phone's Qwen3 number is 1.21.
        var realTimeFactor: Double { wallMilliseconds / audioMilliseconds }
    }

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

    /// Kokoro's own rate, read from the vendor rather than written here —
    /// the same rule `TTSDecoding.sampleRate` exists to keep. A decoder
    /// and a format that disagree is the "drunk voice" fault.
    nonisolated static var sampleRate: Int { KokoroTTS.Constants.samplingRate }

    private var tts: KokoroTTS?
    private var voice: MLXArray?

    /// Loads the weights and one voice style. Both are files the app
    /// downloaded; nothing here reaches the network.
    func load(model: URL, voice voiceURL: URL) throws {
        // BEFORE the weights, not after: the limit must be in place for
        // the very first allocation the loader makes.
        MLX.Memory.cacheLimit = Self.cacheLimitBytes
        // The vendor's `init` force-tries its own weight load, so a
        // corrupt download crashes rather than throws. The download side
        // checks the byte count for exactly that reason.
        let engine = KokoroTTS(modelPath: model, g2p: .misaki)
        let arrays = try MLX.loadArrays(url: voiceURL)
        guard let style = arrays.values.first else {
            throw SpikeFailure.voiceFileEmpty(voiceURL.lastPathComponent)
        }
        tts = engine
        voice = style
    }

    var isLoaded: Bool { tts != nil }

    /// One decode, timed. Returns the samples so the caller can both
    /// measure and LISTEN — a number that nobody hears has been wrong
    /// before in this project.
    func speak(_ text: String) throws -> (samples: [Float], measurement: Measurement) {
        guard let tts, let voice else { throw SpikeFailure.notLoaded }
        let clock = ContinuousClock()
        let start = clock.now
        // `af_heart` is a US voice, so `.enUS`. The vendor picks the
        // language from the caller, never from the voice file.
        let (samples, _) = try tts.generateAudio(voice: voice, language: .enUS, text: text)
        let wall = start.duration(to: clock.now)
        // AFTER the stopwatch stops. Returning the cache is housekeeping,
        // not decoding, and charging it to the decode would make this
        // decoder look slower than it is.
        MLX.Memory.clearCache()
        let audioMilliseconds = Double(samples.count) * 1000 / Double(Self.sampleRate)
        return (samples, Measurement(
            wallMilliseconds: wall.milliseconds,
            audioMilliseconds: audioMilliseconds,
            activeBytes: MLX.Memory.activeMemory,
            peakBytes: MLX.Memory.peakMemory))
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
