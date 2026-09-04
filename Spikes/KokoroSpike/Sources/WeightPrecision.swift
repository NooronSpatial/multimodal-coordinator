import Foundation
import MLX

/// Half-precision weights, made on the phone rather than downloaded.
///
/// **Why this type exists at all.** The plan was to price `bf16` by
/// fetching `mlx-community/Kokoro-82M-bf16`. That repository is
/// mislabelled: its `kokoro-v1_0.safetensors` is **327,115,152 bytes with
/// all 548 tensors `F32`** — byte-for-byte the same file as the fp32
/// mirror, checked by reading both headers. There is no half-precision
/// Kokoro to download.
///
/// So the conversion happens here, once, on the device: load, cast, save
/// beside the original. No hosting, no fork, and the file it writes is
/// the honest artefact — if half precision ruins the voice, the ear finds
/// out in the same session that the memory number does.
enum WeightPrecision: String, CaseIterable, Sendable {
    /// As downloaded. The only one this project has heard.
    case float32
    /// Apple GPUs' native fast path.
    case float16
    /// Same exponent range as fp32, fewer mantissa bits — the safer
    /// choice if fp16 overflows somewhere in the vocoder.
    case bfloat16

    var label: String {
        switch self {
        case .float32: "fp32 (as downloaded)"
        case .float16: "fp16"
        case .bfloat16: "bf16"
        }
    }

    var dtype: DType? {
        switch self {
        case .float32: nil            // no conversion at all
        case .float16: .float16
        case .bfloat16: .bfloat16
        }
    }

    /// Where this precision's weights live. fp32 is the downloaded file
    /// itself; the others are written beside it.
    var location: URL {
        guard self != .float32 else { return SpikeAssets.location(of: SpikeAssets.model) }
        return SpikeAssets.directory.appending(path: "kokoro-\(rawValue).safetensors")
    }

    var isBuilt: Bool {
        guard self != .float32 else { return SpikeAssets.isInstalled(SpikeAssets.model) }
        return FileManager.default.fileExists(atPath: location.path(percentEncoded: false))
    }

    /// Bytes on disk, or nil when it has not been built.
    var bytes: Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path(percentEncoded: false))
        return attributes?[.size] as? Int
    }

    /// Casts every tensor and writes the file. Idempotent: a precision
    /// already built is left alone.
    ///
    /// Written to a temporary name and moved, the same rule the
    /// downloader follows — a conversion interrupted by the app dying
    /// must not leave a half file that `isBuilt` would call ready.
    func build() throws {
        guard let dtype, !isBuilt else { return }
        let source = SpikeAssets.location(of: SpikeAssets.model)
        let arrays = try MLX.loadArrays(url: source)
        let cast = arrays.mapValues { $0.asType(dtype) }
        let partial = SpikeAssets.directory
            .appending(path: "kokoro-\(rawValue).partial.safetensors")
        try MLX.save(arrays: cast, url: partial)
        try? FileManager.default.removeItem(at: location)
        try FileManager.default.moveItem(at: partial, to: location)
        // The cast copies are done with; the next thing that runs is a
        // model load and it should not start behind them.
        MLX.Memory.clearCache()
    }
}
