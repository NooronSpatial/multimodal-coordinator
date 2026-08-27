import Foundation
import TTSKit

// `NeuralVoice`, continued: where the weights live on disk and whether
// all of them are actually here — the folder layout and the honest
// install check.
extension NeuralVoice {
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
    ///
    /// Read from the VENDOR, not guessed (AC-160). The first version chose
    /// `Qwen3-1.7B` for the larger model, but TTSKit hard-wires ONE
    /// tokenizer repo for every variant — so this checked a folder TTSKit
    /// never fills, `modelInstalled()` could never say yes for 1.7B, and
    /// every attempt went to the network: the exact failure the Whisper
    /// audit named, rebuilt by the property whose comment below says it
    /// exists to prevent it (SPEC §118).
    nonisolated var localTokenizerFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models")
            .appending(path: variant.tokenizerRepo)
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
            // NOT-EMPTY IS NOT INSTALLED, and a field report proved it.
            //
            // This used to accept any non-empty folder. A 1.1 GB download
            // interrupted over cellular leaves plenty of non-empty
            // folders, so the app reported the voice INSTALLED and then
            // failed to load it:
            //
            //   Error Domain=com.apple.CoreML Code=71
            //   "…/TextProjector.mlmodelc/model.mil:7:147: Error parsing"
            //
            // A truncated file is not a missing file, and a check that
            // cannot tell them apart sends a person hunting a memory bug
            // that does not exist. So: the compiled bundle must be there,
            // and the file CoreML actually parses must be non-trivial.
            // Cheap — a stat per component, no reading, no hashing — and
            // it catches truncation, which is the failure that happens.
            // FOUND, not assumed. The first version of this looked for the
            // .mlmodelc directly inside the variant folder and reported
            // every component broken — "loaded, but the disk check
            // disagrees" — while TTSKit had loaded the model perfectly.
            // The bundle sits one level deeper, under a QUANTISATION
            // folder whose name differs per component:
            //
            //   text_projector/12hz-0.6b-customvoice/W8A16/TextProjector.mlmodelc
            //   code_embedder/12hz-0.6b-customvoice/W16A16/CodeEmbedder.mlmodelc
            //
            // So it is searched for rather than constructed. Two wrongs in
            // one evening from the same habit: writing down where a file
            // OUGHT to be instead of asking where it IS.
            guard let walker = files.enumerator(at: path,
                                                includingPropertiesForKeys: nil),
                  let bundle = walker.compactMap({ $0 as? URL })
                      .first(where: { $0.pathExtension == "mlmodelc" })
            else { return false }
            let sizeOf: (String) -> Int = { name in
                (try? files.attributesOfItem(
                    atPath: bundle.appending(path: name).path)[.size] as? Int) ?? 0
            }
            // A truncated download leaves the folder present and the file
            // short, which is the failure that actually happens.
            guard sizeOf("model.mil") > 1_024 || sizeOf("coremldata.bin") > 1_024
            else { return false }
        }
        return files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer.json").path)
            && files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer_config.json").path)
    }
}
