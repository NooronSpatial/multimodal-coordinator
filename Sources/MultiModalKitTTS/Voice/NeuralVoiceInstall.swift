import Foundation
import MultiModalKit
import TTSKit

// THE NEURAL MOUTH'S BYTES, THROUGH THE LIBRARY'S DOWNLOADER (5a,
// piece 5; D-114 F-3 = A, F-4 = A, F-5 = A, F-6 = A).
//
// This voice had the same hole the ear had — the vendor fetched ~1.1 GB
// with no progress, no resume and no delete — plus one the ear did not:
// TWO VARIANTS SHARE ONE TREE. `qwen3_tts/` holds both the 0.6B and the
// 1.7B, and the tokenizer repository is hard-wired to ONE
// (`Qwen/Qwen3-0.6B`) for every variant. So a delete that removed the
// family folder would take the other variant with it, and a delete that
// removed the tokenizer would break it.
//
//   models/argmaxinc/ttskit-coreml/qwen3_tts/
//   ├── text_projector/12hz-0.6b-customvoice/W8A16/…      the 0.6B's six directories
//   ├── text_projector/12hz-1.7b-customvoice/W8A16/…      the 1.7B's six, beside them
//   └── …
//   models/Qwen/Qwen3-0.6B/                                the tokenizer, SHARED by both
//
// So this install is variant-scoped: the six `<component>/<versionDir>`
// directories are what a download writes and a delete removes, and the
// tokenizer goes only when no other variant is left to need it.
//
// WHICH FILES, ASKED OF THE VENDOR. The set is
// `TTSKitConfig.downloadPatterns` — six globs, one quantisation per
// component — not a list written here. This repo has been burned twice
// by writing down where a vendor's files OUGHT to be (SPEC §118), and
// the cost of being wrong is a folder that downloads and cannot load.
// Measured 2026-09-22: the patterns select 30 of the family folder's 40
// files, 1 090 543 064 bytes of 1 316 011 614 — the other ten are the
// quantisations this configuration does not load.

/// Where a neural voice's files come from — the vendor's two
/// repositories, and a host a test can point at a loopback server.
public struct NeuralVoiceSource: Sendable, Equatable {
    public let host: URL
    public let modelRepo: String

    public init(host: URL = NeuralVoiceSource.hubHost,
                modelRepo: String = "argmaxinc/ttskit-coreml") {
        self.host = host
        self.modelRepo = modelRepo
    }

    public static let hubHost = URL(string: "https://huggingface.co")!
    public static let hub = NeuralVoiceSource()
}

// MARK: - the catalog

/// One variant's six directories, its scratch, its listing and the
/// shared tokenizer — every path this install touches.
struct NeuralVoiceCatalog: Sendable {
    let variant: TTSModelVariant
    let source: NeuralVoiceSource
    /// `…/ttskit-coreml` — the folder the family directory sits in.
    let modelRoot: URL
    /// `…/ttskit-coreml/qwen3_tts` — the family directory both variants
    /// share.
    let familyFolder: URL
    /// `…/models/Qwen/Qwen3-0.6B` — shared by every variant.
    let tokenizerFolder: URL

    /// The vendor's own file set for this variant, asked of the vendor.
    var patterns: [String] { TTSKitConfig(model: variant).downloadPatterns }
    /// `12hz-0.6b-customvoice` — what makes a directory this variant's.
    var versionDir: String { TTSKitConfig(model: variant).versionDir }
    var tokenizerRepo: String { variant.tokenizerRepo }
    var familyDir: String { familyFolder.lastPathComponent }

    var modelScratch: URL {
        modelRoot.appending(path: "\(familyDir)-\(versionDir).download", directoryHint: .isDirectory)
    }
    var tokenizerScratch: URL {
        tokenizerFolder.deletingLastPathComponent()
            .appending(path: tokenizerFolder.lastPathComponent + ".download", directoryHint: .isDirectory)
    }
    var listingFile: URL {
        modelRoot.appending(path: "\(familyDir)-\(versionDir).listing.json")
    }

    /// The five names the vendor's tokenizer loader asks a folder for —
    /// the same list the ear's catalog uses, and for the same reason.
    static let tokenizerFiles = ["config.json", "tokenizer_config.json", "tokenizer.json",
                                 "chat_template.jinja", "chat_template.json"]

    /// Both repositories, listed — one request each. The model half is
    /// filtered by the VENDOR's globs, so the file set cannot drift from
    /// what TTSKit loads.
    func list() async throws -> NeuralVoiceListing {
        let patterns = patterns
        let model = try await HubTree.list(repo: source.modelRepo, path: familyDir, host: source.host)
        let tokenizer = try await HubTree.list(repo: tokenizerRepo, host: source.host)
        var modelFiles: [String: Int64] = [:]
        for entry in model where patterns.contains(where: { fnmatch($0, entry.path, 0) == 0 }) {
            guard let bytes = entry.bytes else {
                throw DownloadFailure.listingFailed(repo: source.modelRepo, "no size for \(entry.path)")
            }
            // The family directory is the destination's own name, so it
            // is dropped here: `qwen3_tts/text_projector/…` → `text_projector/…`.
            let name = entry.path.hasPrefix(familyDir + "/")
                ? String(entry.path.dropFirst(familyDir.count + 1)) : entry.path
            modelFiles[name] = bytes
        }
        var tokenizerFiles: [String: Int64] = [:]
        for entry in tokenizer where Self.tokenizerFiles.contains(entry.path) {
            guard let bytes = entry.bytes else {
                throw DownloadFailure.listingFailed(repo: tokenizerRepo, "no size for \(entry.path)")
            }
            tokenizerFiles[entry.path] = bytes
        }
        return NeuralVoiceListing(model: modelFiles, tokenizer: tokenizerFiles)
    }

    /// The plan: every model file into the scratch, and the tokenizer's
    /// only when the SHARED folder does not already hold it complete —
    /// the other variant may have fetched it, and 11 MB fetched twice is
    /// a person's data spent for nothing.
    func plan(from listing: NeuralVoiceListing) -> DownloadPlan {
        var files = listing.model.keys.sorted().map { name in
            DownloadPlan.File(
                source: source.host.appending(path: source.modelRepo).appending(path: "resolve/main")
                    .appending(path: familyDir).appending(path: name),
                destination: modelScratch.appending(path: name),
                expectedBytes: listing.model[name])
        }
        for name in listing.tokenizer.keys.sorted() where !tokenizerIsComplete(name, listing.tokenizer[name]) {
            files.append(DownloadPlan.File(
                source: source.host.appending(path: tokenizerRepo)
                    .appending(path: "resolve/main").appending(path: name),
                destination: tokenizerScratch.appending(path: name),
                expectedBytes: listing.tokenizer[name]))
        }
        return DownloadPlan(files: files)
    }

    private func tokenizerIsComplete(_ name: String, _ bytes: Int64?) -> Bool {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: tokenizerFolder.appending(path: name).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == bytes
    }

    /// The six directories into place, one move each, and whatever
    /// tokenizer files were fetched merged into the shared folder.
    ///
    /// PER DIRECTORY, NOT PER FAMILY, which is the whole care here: the
    /// other variant's six directories sit in the same tree, and a swap
    /// of `qwen3_tts` would take them. Each move is over one volume, and
    /// the scratch is complete before any of them begins.
    func place() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: modelScratch.path) else { return }
        for component in TTSKitConfig.componentNames {
            let from = modelScratch.appending(path: component).appending(path: versionDir)
            guard files.fileExists(atPath: from.path) else { continue }
            let into = familyFolder.appending(path: component).appending(path: versionDir)
            do {
                try files.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
                if files.fileExists(atPath: into.path) {
                    _ = try files.replaceItemAt(into, withItemAt: from)
                } else {
                    try files.moveItem(at: from, to: into)
                }
            } catch {
                throw DownloadFailure.couldNotPlace(file: "\(component)/\(versionDir)", String(describing: error))
            }
        }
        try? files.removeItem(at: modelScratch)
        try placeTokenizer()
        exclude(familyFolder)
        exclude(tokenizerFolder)
    }

    /// The tokenizer is MERGED, never swapped: the folder is shared, and
    /// a swap would replace the other variant's copy with whatever this
    /// download happened to need.
    private func placeTokenizer() throws {
        let files = FileManager.default
        guard let fetched = try? files.contentsOfDirectory(atPath: tokenizerScratch.path) else { return }
        do {
            try files.createDirectory(at: tokenizerFolder, withIntermediateDirectories: true)
            for name in fetched {
                let into = tokenizerFolder.appending(path: name)
                if files.fileExists(atPath: into.path) { try files.removeItem(at: into) }
                try files.moveItem(at: tokenizerScratch.appending(path: name), to: into)
            }
        } catch {
            throw DownloadFailure.couldNotPlace(file: tokenizerFolder.lastPathComponent, String(describing: error))
        }
        try? files.removeItem(at: tokenizerScratch)
    }

    /// AC-250's rule, for this engine's gigabyte: a re-downloadable cache
    /// inside a person's iCloud backup is a bill they never agreed to.
    /// Swallowed — a filesystem that will not take the flag is no reason
    /// to throw away a working install.
    private func exclude(_ folder: URL) {
        var marked = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marked.setResourceValues(values)
    }

    /// This variant's six directories — what a delete removes.
    var variantDirectories: [URL] {
        TTSKitConfig.componentNames.map {
            familyFolder.appending(path: $0).appending(path: versionDir)
        }
    }

    /// Whether ANOTHER variant still has files here — the question the
    /// shared tokenizer's fate hangs on.
    func anotherVariantIsInstalled() -> Bool {
        let files = FileManager.default
        for other in TTSModelVariant.allCases where other != variant {
            let otherVersion = TTSKitConfig(model: other).versionDir
            guard otherVersion != versionDir else { continue }
            for component in TTSKitConfig.componentNames {
                let directory = familyFolder.appending(path: component).appending(path: otherVersion)
                if (try? files.contentsOfDirectory(atPath: directory.path))?.isEmpty == false { return true }
            }
        }
        return false
    }
}

/// A variant's files with their sizes, kept beside the family folder so
/// the size can be answered offline and a delete knows what a transfer
/// in flight is moving.
struct NeuralVoiceListing: Codable, Equatable, Sendable {
    var model: [String: Int64]
    var tokenizer: [String: Int64]

    /// The sum, SATURATING — these numbers are decoded off a disk.
    var totalBytes: Int64 {
        (Array(model.values) + Array(tokenizer.values)).reduce(Int64(0)) { total, bytes in
            let (sum, overflowed) = total.addingReportingOverflow(bytes)
            guard !overflowed else { return bytes > 0 ? .max : .min }
            return sum
        }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> NeuralVoiceListing? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NeuralVoiceListing.self, from: data)
    }
}

/// The measured download sizes of this voice's variants (AC-294,
/// F-5 = A). Both repositories are the vendor's, named in the library,
/// so these bytes are a fact about a known pair at a known date —
/// measured 2026-09-22 under the vendor's own `downloadPatterns`, model
/// plus the shared tokenizer:
///
///   0.6B  30 + 3 files  1 091 017 762 + 11 433 112 = 1 102 450 874
///   1.7B  30 + 3 files  2 168 126 409 + 11 433 112 = 2 179 559 521
///
/// AND THE FIRST PAIR WRITTEN HERE WAS WRONG, which is why the live row
/// exists. Those numbers came from patterns RECONSTRUCTED by hand while
/// measuring — with `speech_decoder` at `W8A16`, where the vendor's own
/// default is `W8A16-multifunction` — so the 0.6B was out by 474 698
/// bytes and the 1.7B by 113 MB. `NeuralVoiceInstallLiveTests` asked the
/// real repositories through `TTSKitConfig.downloadPatterns` and
/// convicted both before either reached a commit. It is the same lesson
/// the code already carries (SPEC §118): ask the vendor, never write
/// down where its files ought to be.
enum NeuralVoiceSizes {
    static func measured(for variant: TTSModelVariant) -> Int64? {
        switch variant {
        case .qwen3TTS_0_6b: 1_102_450_874
        case .qwen3TTS_1_7b: 2_179_559_521
        }
    }
}
