import Foundation
import MultiModalKit

// THE EAR'S BYTES, THROUGH THE LIBRARY'S DOWNLOADER (5a, piece 4;
// D-114 F-1 = A, F-3 = A, F-4 = A, F-5 = A, F-6 = A).
//
// Until 5a this engine had no download of its own: `ensureModel()` built
// a `WhisperKit` and let the vendor fetch ~142 MB with no progress, no
// resume, no delete, and no way to know the size first. The diet app's
// Models page showed a spinner with no number for it and could not offer
// a delete at all, because the folder layout is this library's.
//
// TWO REPOSITORIES, ONE VARIANT, and both are the LIBRARY's choice — the
// app names `base` or `small`, never where they come from. That is why
// the sizes can be pinned here (F-5 = A) where the mind's cannot:
//
//   argmaxinc/whisperkit-coreml   openai_whisper-<variant>/…   19 files, the CoreML pipeline
//   openai/whisper-<variant>      tokenizer.json, …             3 files, a SEPARATE asset
//
// The tokenizer is not an optional extra: the vendor's tokenizer load is
// local-FIRST but not local-ONLY, so a missing tokenizer file is a
// silent Hugging Face fetch on the next load. "Installed" has meant
// OFFLINE-CAPABLE here since the Whisper audit, and a download that
// fetched only the model would have quietly broken that.
//
// WHERE THE BYTES LAND, and why not straight into place:
//
//   models/argmaxinc/whisperkit-coreml/openai_whisper-base/             the model      ← modelInstalled() reads
//   models/argmaxinc/whisperkit-coreml/openai_whisper-base.download/    the scratch    ← partials, <file>.resume
//   models/argmaxinc/whisperkit-coreml/openai_whisper-base.listing.json the listing    ← the size, offline
//   models/openai/whisper-base/                                         the tokenizer  ← modelInstalled() reads
//   models/openai/whisper-base.download/                                its scratch
//
// A partial never lives where `modelInstalled()` looks, so a download
// that stopped at 90 % cannot be read as an install — the failure a
// field report already produced once for the neural voice, where a
// truncated 1.1 GB folder was reported installed and then failed to
// load with a CoreML parse error.

/// Where a Whisper variant's files come from. The library's `.hub` is
/// the pair of repositories above; a test points `host` at a loopback
/// server and proves every promise on real bytes over a real socket.
public struct WhisperSource: Sendable, Equatable {
    public let host: URL
    public let modelRepo: String
    /// The tokenizer repository's owner — the name is
    /// `whisper-<variant>`, which the vendor hard-wires.
    public let tokenizerOwner: String

    public init(host: URL = WhisperSource.hubHost,
                modelRepo: String = "argmaxinc/whisperkit-coreml",
                tokenizerOwner: String = "openai") {
        self.host = host
        self.modelRepo = modelRepo
        self.tokenizerOwner = tokenizerOwner
    }

    public static let hubHost = URL(string: "https://huggingface.co")!
    public static let hub = WhisperSource()

    func tokenizerRepo(for variant: String) -> String { "\(tokenizerOwner)/whisper-\(variant)" }
    func modelPrefix(for variant: String) -> String { "openai_whisper-\(variant)" }
}

// MARK: - the catalog

/// One variant's two folders, two scratches and one listing — every path
/// this install touches, named in one place so a delete cannot guess.
struct WhisperCatalog: Sendable {
    let variant: String
    let source: WhisperSource
    let modelFolder: URL
    let tokenizerFolder: URL

    var modelScratch: URL { sibling(of: modelFolder, suffix: ".download") }
    var tokenizerScratch: URL { sibling(of: tokenizerFolder, suffix: ".download") }
    var listingFile: URL { sibling(of: modelFolder, suffix: ".listing.json") }

    /// The five names the vendor's tokenizer loader asks a folder for.
    /// READ FROM THE VENDOR, not guessed: `Hub.loadConfig` downloads
    /// exactly these, and whichever of them a repository actually has is
    /// what an offline load needs. `whisper-base` has three.
    static let tokenizerFiles = ["config.json", "tokenizer_config.json", "tokenizer.json",
                                 "chat_template.jinja", "chat_template.json"]

    private func sibling(of folder: URL, suffix: String) -> URL {
        folder.deletingLastPathComponent()
            .appending(path: folder.lastPathComponent + suffix, directoryHint: .isDirectory)
    }

    /// Both repositories, listed — two requests, one per repository.
    func list() async throws -> WhisperListing {
        let prefix = source.modelPrefix(for: variant)
        let model = try await HubTree.list(repo: source.modelRepo, path: prefix, host: source.host)
        let tokenizer = try await HubTree.list(repo: source.tokenizerRepo(for: variant), host: source.host)
        var modelFiles: [String: Int64] = [:]
        for entry in model {
            // The listing's paths carry the variant folder; the
            // destination does not — the folder IS the variant.
            let name = entry.path.hasPrefix(prefix + "/")
                ? String(entry.path.dropFirst(prefix.count + 1)) : entry.path
            guard let bytes = entry.bytes else {
                throw DownloadFailure.listingFailed(repo: source.modelRepo, "no size for \(entry.path)")
            }
            modelFiles[name] = bytes
        }
        var tokenizerFiles: [String: Int64] = [:]
        for entry in tokenizer where Self.tokenizerFiles.contains(entry.path) {
            guard let bytes = entry.bytes else {
                throw DownloadFailure.listingFailed(repo: source.tokenizerRepo(for: variant),
                                                    "no size for \(entry.path)")
            }
            tokenizerFiles[entry.path] = bytes
        }
        return WhisperListing(model: modelFiles, tokenizer: tokenizerFiles)
    }

    /// The plan: every file into its scratch, at the size the listing
    /// gave — which is what makes a landed file complete or short.
    func plan(from listing: WhisperListing) -> DownloadPlan {
        let prefix = source.modelPrefix(for: variant)
        let model = listing.model.keys.sorted().map { name in
            DownloadPlan.File(
                source: source.host.appending(path: source.modelRepo)
                    .appending(path: "resolve/main").appending(path: prefix).appending(path: name),
                destination: modelScratch.appending(path: name),
                expectedBytes: listing.model[name])
        }
        let tokenizer = listing.tokenizer.keys.sorted().map { name in
            DownloadPlan.File(
                source: source.host.appending(path: source.tokenizerRepo(for: variant))
                    .appending(path: "resolve/main").appending(path: name),
                destination: tokenizerScratch.appending(path: name),
                expectedBytes: listing.tokenizer[name])
        }
        return DownloadPlan(files: model + tokenizer)
    }

    /// Both scratches into place, as two moves over one volume each —
    /// the last act of a transfer whose files are all complete.
    ///
    /// NOTHING IS DESTROYED UNTIL THERE IS SOMETHING COMPLETE TO PUT IN
    /// ITS PLACE, the rule `completeInstall` learned for the mind: the
    /// scratch is whole before either move begins, and a move that fails
    /// leaves the folder it was going to replace exactly as it was.
    func place() throws {
        try place(scratch: modelScratch, into: modelFolder)
        try place(scratch: tokenizerScratch, into: tokenizerFolder)
    }

    private func place(scratch: URL, into folder: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: scratch.path) else { return }
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if files.fileExists(atPath: folder.path) {
                _ = try files.replaceItemAt(folder, withItemAt: scratch)
            } else {
                try files.moveItem(at: scratch, to: folder)
            }
        } catch {
            throw DownloadFailure.couldNotPlace(file: folder.lastPathComponent, String(describing: error))
        }
        // A re-downloadable cache inside a person's iCloud backup is a
        // bill they never agreed to — AC-250's rule, for this engine's
        // 142 MB. Swallowed: a filesystem that will not take the flag is
        // no reason to throw away a working install.
        var marked = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marked.setResourceValues(values)
    }
}

/// A variant's files with their sizes, kept beside the model folder so
/// the size question can be answered with the network unplugged
/// (AC-294) and a delete knows what a transfer in flight is moving.
struct WhisperListing: Codable, Equatable, Sendable {
    var model: [String: Int64]
    var tokenizer: [String: Int64]

    /// The sum, SATURATING — the manifest's arithmetic, for the
    /// manifest's reason: these numbers are decoded off a disk.
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

    /// `nil` when no listing was made, or one this version cannot read.
    static func read(from url: URL) -> WhisperListing? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WhisperListing.self, from: data)
    }
}

// MARK: - what a variant costs, without the network

/// The measured download sizes of the variants this library names
/// (AC-294, F-5 = A).
///
/// PINNED BECAUSE THE LIBRARY CHOSE THEM. Both repositories are named in
/// `WhisperSource`, so these bytes are a fact about a known pair of
/// repositories at a known date — unlike the mind's, whose repository
/// the app picks. Measured 2026-09-22 from the Hub's tree endpoint, both
/// repositories, model plus tokenizer:
///
///   base   19 + 3 files   146 719 453 + 2 765 132 = 149 484 585
///   small  19 + 3 files   486 487 465 + 2 765 116 = 489 252 581
///
/// A NUMBER FROM A DATE IS A NUMBER THAT DRIFTS — the day either
/// repository is re-converted this is stale, which is why
/// `WhisperInstallLiveTests` reads the real listing and fails when it
/// moves, and why a variant not named here answers from the listing this
/// device made, or `nil`. A size nobody measured is not a size.
enum WhisperSizes {
    static let measured: [String: Int64] = ["base": 149_484_585, "small": 489_252_581]
}
