import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-291, AC-293, AC-294, AC-295, AC-296 for the mind (5a, D-114 F-3 = A,
/// F-4 = A, F-5 = A, F-7 = A): the weights through `BackgroundWeightsFetcher`
/// — one request to list, `ModelDownloader` to move — against the
/// counting loopback server.
///
/// The server plays the Hub: it serves the tree endpoint's JSON at
/// `api/models/<repo>/tree/main` and each file at
/// `<repo>/resolve/main/<name>`, and it COUNTS, so "one request to list",
/// "one per file", "a `Range` on the resume" and "never twice the file"
/// are numbers read from the server. The install machinery on the far
/// side — the manifest, the staging, the swap — is 4x's, proved by
/// `MLXInstallSeamTests`; these rows prove what 5a put in front of it.
///
/// Four small files, a few kilobytes each, and every wait is an event:
/// the server saying it has parked, a fraction arriving, a task ending.
@Suite("AC-291/293/294/295/296 · the mind through the downloader", .serialized, .timeLimit(.minutes(1)))
struct MLXBackgroundInstallTests {
    static let repoID = "nobody/Fake-Model"

    // MARK: AC-291 — the transfer, and its fractions

    @Test("one request lists, one per file moves; one byte fraction, 1.0 once; then .installed with a manifest")
    func aFirstInstallThroughTheDownloader() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": 300_000])
        let seen = Mutex<[InstallProgress]>([])
        #expect(model.installState() == .absent)
        #expect(model.expectedDownloadBytes() == nil, "no listing yet — nothing is invented")

        try await model.download(reporting: { progress in seen.withLock { $0.append(progress) } }, using: fetcher)

        let fractions = seen.withLock { $0.map(\.fraction) }
        #expect(fractions == fractions.sorted(), "never decreasing: \(fractions)")
        #expect(fractions.last == 1.0 && fractions.filter { $0 == 1.0 }.count == 1, "1.0 once, last")
        #expect(seen.withLock { $0.allSatisfy { $0.bytesExpected == 300_112 } },
                "the total is known from the first fraction: the listing was written before the first byte")
        #expect(model.installState() == .installed, "a manifest, over a complete tree")
        #expect(bench.server.counts(for: bench.treePath).requests == 1, "ONE request to list")
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            #expect(bench.server.counts(for: bench.filePath(name)).requests == 1, "\(name): once")
        }
        #expect(model.expectedDownloadBytes() == 300_112, "the listing, kept beside the weights")
        #expect(!FileManager.default.fileExists(atPath: bench.scratch.path), "the scratch was moved into place")
    }

    @Test("an installed model reports one 1.0 and asks the server nothing")
    func anInstalledModelReportsOneOne() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": 4_096])
        try await model.download(reporting: { _ in }, using: fetcher)
        let seen = Mutex<[InstallProgress]>([])

        try await model.download(reporting: { progress in seen.withLock { $0.append(progress) } }, using: fetcher)

        #expect(seen.withLock { $0.map(\.fraction) } == [1.0])
        #expect(bench.server.counts(for: bench.treePath).requests == 1, "not even a listing")
        #expect(bench.server.counts(for: bench.filePath("model.safetensors")).requests == 1)
    }

    // MARK: AC-293 — a stopped transfer keeps what resumes; installState never lies

    @Test("a cancel keeps the scratch and its resume data; .absent throughout; the next call resumes with a Range")
    func aCancelResumesNextTime() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let size = 2_097_152
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": size])
        bench.server.hold(bench.filePath("model.safetensors"), after: 262_144)
        let seen = FractionWatcher()

        let first = Task { try await model.download(reporting: { seen.record($0.fraction) }, using: fetcher) }
        await bench.server.parkedConnection()
        // The LARGE file's bytes, not the three small files' (112 bytes of
        // two megabytes): a cancel before its first write has nothing to
        // resume — the row went red under load until the wait said so.
        await seen.fraction(atLeast: 0.02)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        #expect(model.installState() == .absent, "a partial never lives in the weights directory")
        #expect(FileManager.default.fileExists(atPath: bench.scratch.path), "F-4 = A: the scratch stays")
        #expect(FileManager.default.fileExists(
                    atPath: bench.scratch.appending(path: "model.safetensors.resume").path),
                "with the resume data of the unfinished file")
        let paid = bench.server.counts(for: bench.filePath("model.safetensors")).bytesSent
        #expect(paid >= 262_144 && paid < size, "cut mid-file")

        bench.server.release()
        try await model.download(reporting: { _ in }, using: fetcher)

        let counts = bench.server.counts(for: bench.filePath("model.safetensors"))
        #expect(counts.rangeRequests == 1, "resumed, not restarted")
        #expect(counts.bytesSent < 2 * size, "never twice the file: \(counts.bytesSent) of \(size)")
        #expect(bench.server.counts(for: bench.treePath).requests == 2, "each attempt lists once")
        #expect(model.installState() == .installed)
        #expect(!FileManager.default.fileExists(atPath: bench.scratch.path), "moved into place, resume data and all")
    }

    // MARK: AC-294 — the size, exact in one request and then free

    @Test("expectedInstall makes one request and creates no weights; expectedDownloadBytes then answers offline")
    func theSizeIsOneRequestThenFree() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, _) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                               "tokenizer_config.json": 16, "model.safetensors": 8_192])
        #expect(model.expectedDownloadBytes() == nil)

        let size = try await model.expectedInstall(asking: LocalMindModel.treeSizes(host: bench.host))

        #expect(size.downloadBytes == 8_304)
        #expect(size.files.map(\.name)
                == ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        #expect(bench.server.counts(for: bench.treePath).requests == 1, "ONE request")
        #expect(bench.server.counts(for: bench.filePath("model.safetensors")).requests == 0, "and no file")
        #expect(model.installState() == .absent)
        #expect(!FileManager.default.fileExists(atPath: model.weights.path), "no weights directory")

        bench.server.stop()   // the network, unplugged
        #expect(model.expectedDownloadBytes() == 8_304, "the kept listing answers")
    }

    // MARK: AC-295 — the delete

    @Test("deleteModel removes the weights, the manifest, the listing and nothing beside them")
    func deleteModelRemovesWhatWasWrittenAndNothingElse() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": 4_096])
        try await model.download(reporting: { _ in }, using: fetcher)
        // Another model in the same base — this demo keeps Whisper's
        // weights beside the mind's — and the app's own file.
        let sibling = bench.base.appending(path: "whisper-weights")
        try InstallScratch.tree(at: sibling)
        let stranger = bench.base.appending(path: "notes.txt")
        try Data("the app's own".utf8).write(to: stranger)
        #expect(model.installState() == .installed)
        #expect(model.expectedDownloadBytes() != nil)

        try await model.deleteModel(using: fetcher)

        #expect(model.installState() == .absent)
        #expect(model.modelInstalled() == false)
        #expect(!FileManager.default.fileExists(atPath: model.weights.path), "the tree, manifest and all")
        #expect(model.expectedDownloadBytes() == nil, "the listing went with it")
        #expect(!FileManager.default.fileExists(atPath: bench.scratch.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path), "another model's weights: untouched")
        #expect(FileManager.default.fileExists(atPath: stranger.path), "the app's file: untouched")
        #expect(FileManager.default.fileExists(atPath: bench.base.path), "the base itself stays")
    }

    @Test("deleteModel during a transfer stops it, and the caller hears CancellationError")
    func deleteModelStopsATransferInFlight() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": 1_048_576])
        bench.server.hold(bench.filePath("model.safetensors"), after: 65_536)
        let seen = FractionWatcher()

        let download = Task { try await model.download(reporting: { seen.record($0.fraction) }, using: fetcher) }
        await bench.server.parkedConnection()
        await seen.firstFraction()
        try await model.deleteModel(using: fetcher)
        bench.server.release()

        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(model.installState() == .absent)
        #expect(!FileManager.default.fileExists(atPath: bench.scratch.path), "scratch and resume data gone")
        #expect(!FileManager.default.fileExists(atPath: model.weights.path))
    }

    // MARK: AC-296 — the join

    @Test("two concurrent downloads make one transfer, and both return installed")
    func twoDownloadsOneTransfer() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let (model, fetcher) = try bench.mind(files: ["config.json": 32, "tokenizer.json": 64,
                                                     "tokenizer_config.json": 16, "model.safetensors": 524_288])
        bench.server.hold(bench.filePath("model.safetensors"), after: 65_536)
        let one = FractionWatcher(), two = FractionWatcher()

        let first = Task { try await model.download(reporting: { one.record($0.fraction) }, using: fetcher) }
        await bench.server.parkedConnection()
        let second = Task { try await model.download(reporting: { two.record($0.fraction) }, using: fetcher) }
        await two.firstFraction()
        bench.server.release()
        try await first.value
        try await second.value

        #expect(bench.server.counts(for: bench.filePath("model.safetensors")).requests == 1, "one transfer")
        #expect(one.fractions.last == 1.0)
        #expect(two.fractions.last == 1.0)
        #expect(model.installState() == .installed)
    }

    // MARK: the fetch-then-load door, on a real model when this Mac has one

    /// F-7 = A, the door that loads: on an installed model the download
    /// half says `1.0` once and the load half makes the weights resident.
    /// Model-gated the way the live suites are (`MMK_MLX_MODEL`), and
    /// GPU-gated because a load without a metallib aborts the process.
    @Test("ensureModel(progress:) on an installed model: one 1.0, then resident",
          .enabled(if: LiveWeights.url != nil && MLXRuntime.isAvailable,
                   "set MMK_MLX_MODEL and run Scripts/metallib.sh to make this row real"))
    func ensureModelWithProgressLoads() async throws {
        let model = LocalMindModel(weights: try #require(LiveWeights.url))
        let seen = FractionWatcher()

        try await model.ensureModel(progress: seen.record)

        #expect(seen.fractions == [1.0])
        #expect(await model.isResident)
        await model.retire()
    }
}

/// The live weights, when this machine has them — the house pattern.
enum LiveWeights {
    static var url: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - the bench, playing the Hub

extension DownloadBench {
    var host: URL { URL(string: "http://127.0.0.1:\(server.port)")! }
    var base: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }
    var scratch: URL { base.appending(path: "Fake-Model.download") }
    var treePath: String { "api/models/\(MLXBackgroundInstallTests.repoID)/tree/main" }

    func filePath(_ name: String) -> String { "\(MLXBackgroundInstallTests.repoID)/resolve/main/\(name)" }

    /// A model over this bench's server: the tree endpoint's JSON for
    /// `files` (with a `.bin` the globs never fetch, so the filter is
    /// exercised), one served file per entry, and a fetcher on this
    /// bench's downloader.
    func mind(files: [String: Int]) throws -> (LocalMindModel, BackgroundWeightsFetcher) {
        var entries = files.sorted { $0.key < $1.key }.map { name, bytes in
            #"{"type":"file","oid":"x","size":\#(bytes),"path":"\#(name)"}"#
        }
        entries.append(#"{"type":"file","oid":"x","size":999999,"path":"model.bin"}"#)
        entries.append(#"{"type":"directory","oid":"x","path":"assets"}"#)
        try serve(treePath, text: "[" + entries.joined(separator: ",") + "]")
        for (name, bytes) in files {
            try FileManager.default.createDirectory(at: root.appending(path: "served/\(filePath(name))")
                                                        .deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try serve(filePath(name), bytes: bytes)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = LocalMindModel(repoID: MLXBackgroundInstallTests.repoID, in: base)
        let fetcher = BackgroundWeightsFetcher(host: host, downloader: downloader,
                                               sizes: LocalMindModel.treeSizes(host: host))
        return (model, fetcher)
    }
}
