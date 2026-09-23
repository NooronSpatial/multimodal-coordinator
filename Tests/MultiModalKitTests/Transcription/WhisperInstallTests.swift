import Foundation
import Testing
@testable import MultiModalKit

#if canImport(MultiModalKitWhisper)
@testable import MultiModalKitWhisper

/// AC-291, AC-294, AC-295 for the Whisper ear (5a, piece 4; D-114
/// F-3 = A, F-4 = A, F-5 = A, F-6 = A): two repositories, one variant,
/// through the downloader — against the counting loopback server.
///
/// The real download is ~142 MB across 22 files in two repositories;
/// these rows serve a handful of small files at their declared sizes and
/// prove every promise on real bytes over a real socket. What they watch
/// is the thing this engine could not say before: a percentage, a size
/// before the tap, a delete that removes exactly its own variant, and a
/// tokenizer that is fetched as part of "installed" rather than left to
/// a silent load-time fetch.
///
/// THE VENDOR'S LAYOUT, UNDER THE BENCH'S OWN ROOT. The paths below the
/// root are the vendor's and no row chooses them; the root itself is
/// redirected, so these rows never write into a person's real model
/// folders. The variant name is unique per bench as well, so two rows
/// running together cannot collide. A stranger's folder beside the
/// model is written by hand and asserted untouched.
@Suite("AC-291/294/295 · Whisper through the downloader", .serialized, .timeLimit(.minutes(1)))
struct WhisperInstallTests {

    @Test("both repositories arrive under one fraction; then installed, with the tokenizer")
    func bothRepositoriesArriveUnderOneFraction() async throws {
        let bench = try WhisperBench()
        defer { bench.tearDown() }
        let seen = FractionWatcher()
        #expect(await !bench.engine.modelInstalled())

        try await bench.engine.download(progress: seen.record)

        let fractions = seen.fractions
        #expect(fractions == fractions.sorted(), "never decreasing: \(fractions)")
        #expect(fractions.last == 1.0 && fractions.filter { $0 == 1.0 }.count == 1, "1.0 once, last")
        #expect(await bench.engine.modelInstalled())
        #expect(bench.server.counts(for: bench.modelTreePath).requests == 1, "one request per repository")
        #expect(bench.server.counts(for: bench.tokenizerTreePath).requests == 1)
        #expect(bench.exists("model/MelSpectrogram.mlmodelc/coremldata.bin"), "the nested model file landed")
        #expect(bench.exists("tokenizer/tokenizer.json"), "and the tokenizer, which the load needs")
        #expect(bench.exists("tokenizer/config.json"))
        #expect(!bench.exists("scratch/model"), "the scratches were moved into place")
        #expect(!bench.exists("scratch/tokenizer"))
    }

    @Test("an installed variant reports one 1.0 and asks the server nothing")
    func anInstalledVariantAsksNothing() async throws {
        let bench = try WhisperBench()
        defer { bench.tearDown() }
        try await bench.engine.download()
        let seen = FractionWatcher()

        try await bench.engine.download(progress: seen.record)

        #expect(seen.fractions == [1.0])
        #expect(bench.server.counts(for: bench.modelTreePath).requests == 1, "not even a listing")
        #expect(bench.server.counts(for: bench.filePath("tokenizer.json", tokenizer: true)).requests == 1)
    }

    /// A partial must never be readable as an install — the failure a
    /// field report produced for the neural voice, where a truncated
    /// download was reported installed and then failed to load.
    @Test("a stopped transfer leaves nothing installed, keeps its scratch, and resumes next time")
    func aStoppedTransferKeepsItsScratch() async throws {
        let bench = try WhisperBench(weightBytes: 1_048_576)
        defer { bench.tearDown() }
        bench.server.hold(bench.filePath("AudioEncoder.mlmodelc/weights/weight.bin"), after: 131_072)
        let seen = FractionWatcher()

        let first = Task { try await bench.engine.download(progress: seen.record) }
        await bench.server.parkedConnection()
        await seen.fraction(atLeast: 0.05)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        #expect(await !bench.engine.modelInstalled(), "a partial is not an install")
        #expect(!bench.exists("model/AudioEncoder.mlmodelc/weights/weight.bin"),
                "and nothing of it is where the check looks")
        #expect(bench.exists("scratch/model/AudioEncoder.mlmodelc/weights/weight.bin.resume"),
                "F-4 = A: what can be resumed is kept")

        bench.server.release()
        try await bench.engine.download()

        let counts = bench.server.counts(for: bench.filePath("AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(counts.rangeRequests == 1, "resumed, not restarted")
        #expect(counts.bytesSent < 2 * 1_048_576, "never twice the file: \(counts.bytesSent)")
        #expect(await bench.engine.modelInstalled())
    }

    @Test("the size is known without the network: the measured variants, then this device's listing")
    func theSizeIsKnownWithoutTheNetwork() async throws {
        let bench = try WhisperBench()
        defer { bench.tearDown() }
        // A variant nobody measured: no guess until this device lists.
        #expect(bench.engine.expectedDownloadBytes() == nil)

        try await bench.engine.download()

        #expect(bench.engine.expectedDownloadBytes() == bench.totalBytes, "the listing it made")
        // The variants this library names, measured 2026-09-22 against
        // both real repositories (the live row re-reads them).
        #expect(WhisperEngine(model: "base").expectedDownloadBytes() == 149_484_585)
        #expect(WhisperEngine(model: "small").expectedDownloadBytes() == 489_252_581)
    }

    @Test("deleteModel removes this variant's folders and listing, and nothing beside them")
    func deleteModelRemovesThisVariantOnly() async throws {
        let bench = try WhisperBench()
        defer { bench.tearDown() }
        try await bench.engine.download()
        let sibling = bench.modelFolder.deletingLastPathComponent().appending(path: "openai_whisper-stranger")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("another variant".utf8).write(to: sibling.appending(path: "coremldata.bin"))
        #expect(await bench.engine.modelInstalled())

        try await bench.engine.deleteModel()

        #expect(await !bench.engine.modelInstalled())
        #expect(!bench.exists("model"), "the model folder")
        #expect(!bench.exists("tokenizer"), "and the tokenizer folder — a download wrote both")
        #expect(bench.engine.expectedDownloadBytes() == nil, "the listing went with them")
        #expect(FileManager.default.fileExists(atPath: sibling.path),
                "another variant under the same hub directory: untouched")
        #expect(FileManager.default.fileExists(atPath: sibling.deletingLastPathComponent().path),
                "and the directory holding them both")
    }

    @Test("deleteModel during a transfer stops it, and the caller hears CancellationError")
    func deleteModelStopsATransferInFlight() async throws {
        let bench = try WhisperBench(weightBytes: 1_048_576)
        defer { bench.tearDown() }
        bench.server.hold(bench.filePath("AudioEncoder.mlmodelc/weights/weight.bin"), after: 131_072)
        let seen = FractionWatcher()

        let transfer = Task { try await bench.engine.download(progress: seen.record) }
        await bench.server.parkedConnection()
        await seen.fraction(atLeast: 0.05)
        try await bench.engine.deleteModel()
        bench.server.release()

        await #expect(throws: CancellationError.self) { try await transfer.value }
        #expect(await !bench.engine.modelInstalled())
        #expect(!bench.exists("scratch/model"), "scratch and resume data gone")
    }
}

/// The load half of `ensureModel(progress:)`, on a machine that really
/// has the model (5a, piece 4): the bytes are already there, so the
/// download half says `1.0` once and the vendor's pipeline loads from
/// disk — with `download: false` on its config, which since 5a means a
/// load can no longer quietly fetch.
///
/// Model-gated the way every live row here is: it runs where
/// `base` is installed, and says so when it skips.
@Suite("AC-291 · the ear's load half, when this machine has the model",
       .enabled(if: WhisperLive.baseIsInstalled,
                "install Whisper base (swift run bakeoff fetch) to make this row real"),
       .timeLimit(.minutes(5)))
struct WhisperEnsureModelLiveTests {
    @Test("ensureModel(progress:) on an installed variant: one 1.0, then a loaded pipeline")
    func ensureModelLoadsWhatIsAlreadyThere() async throws {
        let engine = WhisperEngine(model: "base")
        let seen = FractionWatcher()

        try await engine.ensureModel(progress: seen.record)

        #expect(seen.fractions == [1.0], "the bytes were there; the bar says so once")
        // The pipeline really loaded: a decode of silence returns without
        // throwing, which is the only thing a loaded Whisper owes here.
        let run = try await engine.openRun(format: AudioStreamFormat(sampleRate: 16_000, channels: 1))
        await run.cancel()
    }
}

enum WhisperLive {
    static var baseIsInstalled: Bool {
        let folder = URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base")
        let tokenizer = URL.documentsDirectory
            .appending(path: "huggingface/models/openai/whisper-base/tokenizer.json")
        let files = FileManager.default
        return (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == false
            && files.fileExists(atPath: tokenizer.path)
    }
}

/// The real repositories, read — the pin that catches the day either one
/// is re-converted and `WhisperSizes.measured` goes stale.
///
/// OPT-IN, because it is the only row in this house that touches the
/// network: `MMK_LIVE_HUB=1`. CI stays hermetic; the number is taken by
/// hand and written into `docs/evidence/5a/` with its date.
@Suite("AC-294 · the measured variants, against the real repositories",
       .enabled(if: ProcessInfo.processInfo.environment["MMK_LIVE_HUB"] == "1",
                "set MMK_LIVE_HUB=1 to ask huggingface.co"),
       .timeLimit(.minutes(1)))
struct WhisperInstallLiveTests {
    @Test("base and small still cost what this library says they cost", arguments: ["base", "small"])
    func theMeasuredSizesStillHold(variant: String) async throws {
        let engine = WhisperEngine(model: variant)
        let listed = try await engine.liveListing().totalBytes
        #expect(listed == WhisperSizes.measured[variant],
                "\(variant): the repositories now hold \(listed) bytes — update WhisperSizes with today's date")
    }
}

extension WhisperEngine {
    /// The catalog's listing, for the live row — the same two requests
    /// `ensureModel` makes.
    func liveListing() async throws -> WhisperListing {
        try await WhisperCatalog(variant: modelName, source: .hub,
                                 modelFolder: modelFolderURL,
                                 tokenizerFolder: tokenizerFolderURL).list()
    }
}

// MARK: - the bench

/// A loopback Hub serving one variant's files, and an engine pointed at
/// it. The variant name is unique per bench, so the engine's real
/// folders under `Documents` cannot collide with a real install or with
/// another row.
struct WhisperBench {
    let server: LoopbackFileServer
    let engine: WhisperEngine
    let downloader: ModelDownloader
    let variant: String
    let root: URL
    let modelFolder: URL
    let tokenizerFolder: URL
    let totalBytes: Int64

    /// The model files these rows serve — a nested one, so the
    /// destination's subdirectories are proved to be created, and the
    /// three the tokenizer load needs.
    static let modelFiles = ["MelSpectrogram.mlmodelc/coremldata.bin": 512,
                             "AudioEncoder.mlmodelc/weights/weight.bin": 4_096,
                             "config.json": 128]
    static let tokenizerFiles = ["config.json": 64, "tokenizer.json": 256, "tokenizer_config.json": 128]

    init(weightBytes: Int? = nil) throws {
        variant = "mmk-test-\(UUID().uuidString.prefix(8))"
        root = FileManager.default.temporaryDirectory.appending(path: "whisper-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "served"),
                                                withIntermediateDirectories: true)
        server = try LoopbackFileServer(directory: root.appending(path: "served"))
        let host = URL(string: "http://127.0.0.1:\(server.port)")!
        downloader = ModelDownloader(
            configuration: .background(withIdentifier: "whisper-bench.\(UUID().uuidString)"))
        engine = WhisperEngine(model: variant, language: nil, diagnostics: nil,
                               source: WhisperSource(host: host), downloader: downloader,
                               installRoot: root)
        modelFolder = root
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
            .appending(path: "openai_whisper-\(variant)")
        tokenizerFolder = root
            .appending(path: "huggingface/models/openai")
            .appending(path: "whisper-\(variant)")

        var model = Self.modelFiles
        if let weightBytes { model["AudioEncoder.mlmodelc/weights/weight.bin"] = weightBytes }
        totalBytes = Int64(model.values.reduce(0, +) + Self.tokenizerFiles.values.reduce(0, +))
        try serveTree(model: model)
    }

    func tearDown() {
        server.stop()
        let downloader = downloader
        Task { await downloader.invalidate() }
        // Everything this bench wrote — the vendor's layout included —
        // is under its own root, so one removal takes all of it and
        // nothing of the person's own (the neural voice's bench learned
        // this the hard way, reading a real install as its own).
        try? FileManager.default.removeItem(at: root)
    }

    var modelTreePath: String { "api/models/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-\(variant)" }
    var tokenizerTreePath: String { "api/models/openai/whisper-\(variant)/tree/main" }

    func filePath(_ name: String, tokenizer: Bool = false) -> String {
        tokenizer
            ? "openai/whisper-\(variant)/resolve/main/\(name)"
            : "argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-\(variant)/\(name)"
    }

    /// One of the bench's landmarks, by a short name: `model`,
    /// `tokenizer`, `scratch/model`, `scratch/tokenizer`, each optionally
    /// followed by a path inside it.
    func exists(_ what: String) -> Bool {
        let parts = what.split(separator: "/", maxSplits: 1).map(String.init)
        let scratched = parts.first == "scratch"
        let rest = scratched
            ? (parts.count > 1 ? parts[1].split(separator: "/", maxSplits: 1).map(String.init) : [])
            : parts
        guard let which = rest.first else { return false }
        let folder: URL
        switch which {
        case "model": folder = scratched ? scratch(modelFolder) : modelFolder
        case "tokenizer": folder = scratched ? scratch(tokenizerFolder) : tokenizerFolder
        default: return false
        }
        let url = rest.count > 1 ? folder.appending(path: rest[1]) : folder
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func scratch(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".download")
    }

    /// Both repositories' trees, and a file for every entry.
    private func serveTree(model: [String: Int]) throws {
        let prefix = "openai_whisper-\(variant)"
        var modelRows = model.sorted { $0.key < $1.key }.map { name, bytes in
            #"{"type":"file","oid":"x","size":\#(bytes),"path":"\#(prefix)/\#(name)"}"#
        }
        modelRows.append(#"{"type":"directory","oid":"x","path":"\#(prefix)/AudioEncoder.mlmodelc"}"#)
        try serve(modelTreePath, text: "[" + modelRows.joined(separator: ",") + "]")

        var tokenizerRows = Self.tokenizerFiles.sorted { $0.key < $1.key }.map { name, bytes in
            #"{"type":"file","oid":"x","size":\#(bytes),"path":"\#(name)"}"#
        }
        // A file the loader never asks for — the filter must drop it.
        tokenizerRows.append(#"{"type":"file","oid":"x","size":999999,"path":"model.safetensors"}"#)
        try serve(tokenizerTreePath, text: "[" + tokenizerRows.joined(separator: ",") + "]")

        for (name, bytes) in model { try serve(filePath(name), bytes: bytes) }
        for (name, bytes) in Self.tokenizerFiles { try serve(filePath(name, tokenizer: true), bytes: bytes) }
    }

    private func serve(_ name: String, text: String) throws {
        let file = root.appending(path: "served/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func serve(_ name: String, bytes: Int) throws {
        let file = root.appending(path: "served/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        for index in stride(from: 0, to: bytes, by: 4_096) { data[index] = UInt8(truncatingIfNeeded: index / 4_096) }
        try data.write(to: file)
    }
}
#endif
