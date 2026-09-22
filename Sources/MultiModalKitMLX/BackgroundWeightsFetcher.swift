import Foundation
import MultiModalKit

// THE MIND'S BYTES, THROUGH THE LIBRARY'S DOWNLOADER (5a, SPEC §202,
// D-114 F-1 = A, F-3 = A, F-4 = A, F-5 = A).
//
// Before 5a the mind's weights came down through the Hub client's
// `snapshot`, on a foreground session, counting FILES; a stopped
// download was deleted (D-106 F-2 = A, F-3 = A). Both rulings named
// this milestone as their end, and the reason is measured: the
// client's own background switch crashes the process
// (`docs/evidence/5a/probes/probe1.out.txt`), so a transfer that goes on
// while the app is suspended has to be one this library owns.
//
// This conformer is that: ONE request lists the repository with sizes
// (the Hub's tree endpoint — `docs/evidence/5a`, Fact 4), the listing
// becomes a `DownloadPlan` into a scratch directory beside the weights,
// and `ModelDownloader` moves the bytes on the background session. The
// install itself — the manifest, the staging, the swap — is unchanged
// from 4x: this fetcher hands back a directory, and `completeInstall`
// does what it always did with one.
//
//   base/
//   ├── Qwen3-4B-4bit/               the weights  (installState() reads this, and only this)
//   ├── Qwen3-4B-4bit.download/      the scratch  (the plan's destinations; <file>.resume beside a stopped one)
//   ├── Qwen3-4B-4bit.incoming/      the staging  (completeInstall's, gone after the swap)
//   └── Qwen3-4B-4bit.listing.json   the listing  (the size without the network, F-5 = A)

/// The fetcher `download(reporting:)` uses by default since 5a: the
/// repository's files, listed in one request and moved by
/// `ModelDownloader` on the library's background session.
///
/// `host` is the Hub (`https://huggingface.co`) unless a mirror is named;
/// the tests point it at a loopback server and prove every promise on
/// real bytes over a real socket.
public struct BackgroundWeightsFetcher: WeightsFetching {
    let host: URL
    let downloader: ModelDownloader
    let sizes: LocalMindModel.Sizing

    /// The library's fetcher: the Hub, on the shared background session.
    public init(host: URL = LocalMindModel.hubHost) {
        self.init(host: host, downloader: .shared, sizes: LocalMindModel.treeSizes(host: host))
    }

    /// The tests' door: a host of the test's own, a downloader of its
    /// own, and — when a row wants no socket at all — a listing of its own.
    init(host: URL, downloader: ModelDownloader, sizes: @escaping LocalMindModel.Sizing) {
        self.host = host
        self.downloader = downloader
        self.sizes = sizes
    }

    /// Lists, plans, transfers; returns the scratch directory holding
    /// every file complete.
    ///
    /// WHAT A STOPPED TRANSFER LEAVES (F-4 = A): the scratch, with the
    /// downloader's resume data beside each unfinished file. A cancel
    /// throws `CancellationError` out of here; a lost connection throws
    /// `DownloadFailure` — and either way the next call lists again
    /// (one request), finds the complete files complete, resumes the
    /// rest, and asks for nothing twice. Nothing of this ever lives in
    /// the weights directory, so `installState()` cannot lie.
    ///
    /// The listing is written beside the weights BEFORE the first byte
    /// moves, so `expectedDownloadBytes()` — and the byte fields of the
    /// progress this transfer reports — know the total from then on.
    public func fetch(repoID: String,
                      into base: URL,
                      reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let listing = try await WeightsListing.list(repoID: repoID, asking: sizes)
        guard !listing.files.isEmpty else {
            let globs = LocalMindModel.weightGlobs.joined(separator: ", ")
            throw InstallFailure.fetchFailed("\(repoID) lists no weight files (\(globs))")
        }
        try listing.write(for: repoID, under: base)
        let scratch = Self.scratch(repoID: repoID, under: base)
        try await downloader.transfer(plan(for: repoID, from: listing, into: scratch), progress: progress)
        return scratch
    }

    /// The delete's half (AC-295): a transfer in flight is stopped and
    /// its resume data dropped, then the scratch and the listing go.
    public func discard(repoID: String, under base: URL) async {
        let scratch = Self.scratch(repoID: repoID, under: base)
        if let listing = WeightsListing.read(for: repoID, under: base) {
            await downloader.discard(plan(for: repoID, from: listing, into: scratch))
        }
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: WeightsListing.location(for: repoID, under: base))
    }

    /// Where this fetcher works: a sibling of the weights, never inside
    /// them — strictly below `base`, which is what `completeInstall`'s
    /// deletion guard requires of a returned directory.
    static func scratch(repoID: String, under base: URL) -> URL {
        base.appending(path: LocalMindModel.weightsName(for: repoID) + ".download", directoryHint: .isDirectory)
    }

    /// One `DownloadPlan.File` per listed file: the Hub's `resolve` URL,
    /// its place in the scratch, and the size the listing gave — which is
    /// what makes a landed file complete or short.
    private func plan(for repoID: String, from listing: WeightsListing, into scratch: URL) -> DownloadPlan {
        DownloadPlan(files: listing.files.keys.sorted().map { name in
            DownloadPlan.File(
                source: host.appending(path: repoID).appending(path: "resolve/main").appending(path: name),
                destination: scratch.appending(path: name),
                expectedBytes: listing.files[name])
        })
    }
}

// MARK: - the listing, and where it is kept

/// A repository's weight files with their sizes — the one request's
/// answer, kept beside the weights as `<name>.listing.json` so the size
/// question can be answered with the network unplugged (AC-294, F-5 = A:
/// the app chose this repository, so the library cannot pin its bytes,
/// but it can remember a listing it made).
struct WeightsListing: Codable, Equatable, Sendable {
    /// File name → bytes, for every file the download would fetch.
    var files: [String: Int64]

    /// The sum, saturating — the manifest's arithmetic, for the manifest's
    /// reason (numbers decoded off a disk are not counted here).
    var totalBytes: Int64 {
        files.values.reduce(Int64(0)) { total, bytes in
            let (sum, overflowed) = total.addingReportingOverflow(bytes)
            guard !overflowed else { return bytes > 0 ? .max : .min }
            return sum
        }
    }

    /// Asks the sizing source and keeps only the files the download's
    /// globs name — re-applied here for the reason `expectedInstall`
    /// gives: a source that ignores what it was asked for still cannot
    /// make this a listing of a different set of files.
    static func list(repoID: String, asking sizes: LocalMindModel.Sizing) async throws -> WeightsListing {
        let listed = try await sizes(repoID, LocalMindModel.weightGlobs)
        var files: [String: Int64] = [:]
        for file in listed where LocalMindModel.matchesWeightGlob(file.name) {
            files[file.name] = file.bytes
        }
        return WeightsListing(files: files)
    }

    static func location(for repoID: String, under base: URL) -> URL {
        base.appending(path: LocalMindModel.weightsName(for: repoID) + ".listing.json")
    }

    func write(for repoID: String, under base: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.location(for: repoID, under: base), options: .atomic)
    }

    /// `nil` when no listing was ever made, or one this version cannot
    /// read — a size nobody knows is not a size.
    static func read(for repoID: String, under base: URL) -> WeightsListing? {
        guard let data = try? Data(contentsOf: location(for: repoID, under: base)) else { return nil }
        return try? JSONDecoder().decode(WeightsListing.self, from: data)
    }
}

// MARK: - the one request

extension LocalMindModel {
    /// Where the weights come from unless a caller names a mirror.
    public static let hubHost = URL(string: "https://huggingface.co")!

    /// The directory name this model's weights live under, from its
    /// repository id: `mlx-community/Qwen3-4B-4bit` → `Qwen3-4B-4bit`.
    /// ONE function, because the fetcher's scratch and listing are named
    /// from it too, and two spellings of one name would be two models.
    static func weightsName(for repoID: String) -> String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }

    /// The repository's files with their sizes in ONE request — the Hub's
    /// tree endpoint, `GET <host>/api/models/<repo>/tree/main?recursive=true`,
    /// which answers every file's `size` (the true size for a large file,
    /// not its pointer's). Measured on 2026-09-19: the 4B's nine files in
    /// 0.22 s (`docs/evidence/5a`, Fact 4), where the client's
    /// `getFilenames` + `getFileMetadata` per file cost ten listings and
    /// nine HEADs.
    ///
    /// ITS OWN SESSION, not `.shared`. A foreground one — this is a
    /// question answered in a moment, not a transfer — but the library's,
    /// ephemeral, for two reasons. The process-global `URLProtocol`
    /// registry reaches `URLSession.shared` and nothing else, and the
    /// network-silence proof (AC-252, `NetworkSilenceTests`) listens
    /// there for requests a LOAD leaks; a listing is a request this
    /// library makes on purpose, at a person's ask, and it must not be
    /// mistaken for a leak by a suite running beside it — the full suite
    /// went red exactly that way while this file was written. And an
    /// ephemeral session shares no cookies and no cache with the app's
    /// own traffic, so the answer is the server's every time.
    static let listingSession = URLSession(configuration: .ephemeral)

    static func treeSizes(host: URL, session: URLSession = listingSession) -> Sizing {
        { repoID, globs in
            var components = URLComponents(url: host.appending(path: "api/models").appending(path: repoID)
                                                .appending(path: "tree/main"),
                                           resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]
            guard let url = components?.url else { throw InstallFailure.fetchFailed("no URL for \(repoID)") }
            let (data, response) = try await session.data(from: url)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw InstallFailure.fetchFailed("listing \(repoID): the server answered \(status)")
            }
            let entries: [TreeEntry]
            do {
                entries = try JSONDecoder().decode([TreeEntry].self, from: data)
            } catch {
                throw InstallFailure.fetchFailed("listing \(repoID): \(String(describing: error))")
            }
            return try entries.filter { $0.type == "file" }.compactMap { entry in
                guard globs.contains(where: { fnmatch($0, entry.path, 0) == 0 }) else { return nil }
                guard let size = entry.size else { throw InstallFailure.sizeUnknown(file: entry.path) }
                return InstallSize.FileSize(name: entry.path, bytes: size)
            }
        }
    }

    /// One row of the tree endpoint's answer — the three fields this
    /// library reads, and nothing it does not.
    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }
}
