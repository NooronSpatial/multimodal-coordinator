import Foundation
import MultiModalKit
import TTSKit

/// The second mouth (SPEC §61, D-045): Qwen3 neural TTS behind the same
/// `SpeechSynthesizing` seam Apple's voice already implements.
///
/// The milestone's reason to exist: every seam in this library has two
/// real implementations except this one, so "we can switch mouths" was a
/// CLAIM where the input side had a PROOF. The proof is a bake-off.
///
/// **What this type does NOT do, by ruling (D-045 F-1 = B):** it never
/// asks TTSKit to play anything. It takes the PCM from `generate` and
/// renders it through the pipeline's own engine, because D-043 measured
/// that iOS voice processing cancels only what its own audio unit
/// renders — so a reply we render ourselves is the first one the
/// canceller can see. The cost, accepted knowingly: pre-buffering and
/// resampling become ours to get right.
///
/// This file's first job is the part that can be tested without a
/// speaker: knowing whether the model is here, and saying so honestly.
/// An actor for the same reason `WhisperEngine` is one: it caches a
/// loaded CoreML pipeline, and that is mutable state which must not be
/// touched from two places at once.
public actor NeuralVoice {
    /// Which Qwen3 variant to speak with. 0.6B is the smaller, faster
    /// one; the bake-off's numbers decide whether the larger earns its
    /// download.
    /// `nonisolated` because it never changes and callers ask it while
    /// printing — an actor hop to read a `let` is ceremony.
    public nonisolated let variant: TTSModelVariant

    /// The loaded pipeline, kept so a second utterance does not pay the
    /// load again.
    private var pipeline: TTSKit?

    public init(variant: TTSModelVariant = .qwen3TTS_0_6b) {
        self.variant = variant
    }

    /// Where TTSKit's hub actually places this variant — MEASURED, not
    /// guessed. The first version of this property guessed
    /// `argmaxinc/tts-coreml/qwen3-tts-0.6b` and was wrong on both
    /// halves; the install printed "the load succeeded but the disk
    /// check says NOT installed", which is the message existing to
    /// catch exactly that.
    ///
    /// Named explicitly rather than left to the library's default, and
    /// that is a Phase 2 lesson rather than a preference: WhisperKit
    /// pinged Hugging Face on EVERY pipeline load until its
    /// `modelFolder` was handed over — an offline failure, a privacy
    /// footnote, and a 4× cost on every test load, all from a default.
    nonisolated var localModelFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/ttskit-coreml")
            .appending(path: "qwen3_tts")
    }

    /// The component directory each variant's weights live in
    /// (`code_decoder/12hz-0.6b-customvoice`, and five siblings).
    nonisolated var variantDirectoryName: String {
        switch variant {
        case .qwen3TTS_1_7b: "12hz-1.7b-customvoice"
        default: "12hz-0.6b-customvoice"
        }
    }

    /// The TOKENIZER, which lives in a different repo entirely
    /// (`Qwen/Qwen3-0.6B`) — 11 MB beside 1.1 GB of CoreML.
    nonisolated var localTokenizerFolder: URL {
        let repo = variant == .qwen3TTS_1_7b ? "Qwen3-1.7B" : "Qwen3-0.6B"
        return URL.documentsDirectory
            .appending(path: "huggingface/models/Qwen")
            .appending(path: repo)
    }

    /// Honest disk check — asking never triggers a download.
    ///
    /// "Installed" means OFFLINE-CAPABLE, and the Whisper audit's finding
    /// repeats here EXACTLY: the model folder alone is not enough,
    /// because the tokenizer is a separate asset in a separate repo whose
    /// absence sends the loader to the network. So this asks for all six
    /// CoreML components AND the tokenizer files by name. Anything less
    /// lets "installed" quietly mean "installed plus one download".
    public nonisolated func modelInstalled() async -> Bool {
        let files = FileManager.default
        let components = ["code_decoder", "code_embedder", "multi_code_decoder",
                          "multi_code_embedder", "speech_decoder", "text_projector"]
        for component in components {
            let path = localModelFolder
                .appending(path: component)
                .appending(path: variantDirectoryName)
            guard let contents = try? files.contentsOfDirectory(atPath: path.path),
                  !contents.isEmpty
            else { return false }
        }
        return files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer.json").path)
            && files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer_config.json").path)
    }

    /// Downloads the model if it is missing, then loads the pipeline.
    /// Idempotent: with the assets on disk this is a load, not a fetch.
    ///
    /// No progress callback, deliberately. The first draft of this method
    /// had one, and it was decoration: it reported 1.0 when the await
    /// returned and nothing before — a fake instrument in a repo whose
    /// whole method is refusing those. TTSKit's own `verbose` logging is
    /// the honest reporter until a real one is needed.
    /// Returns nothing on purpose: handing a `TTSKit` back would drag
    /// the dependency into every caller's imports, which is the opposite
    /// of what an opt-in module is for (D-045 F-4). The pipeline stays
    /// in here.
    public func ensureModel() async throws {
        pipeline = try await loadedPipeline()
    }

    /// Loads once, then reuses. The variant's own logging reports the
    /// download; this only owns the caching.
    private func loadedPipeline() async throws -> TTSKit {
        if let pipeline { return pipeline }
        let fresh = try await TTSKit(TTSKitConfig(model: variant, download: true, load: true))
        pipeline = fresh
        return fresh
    }
}
