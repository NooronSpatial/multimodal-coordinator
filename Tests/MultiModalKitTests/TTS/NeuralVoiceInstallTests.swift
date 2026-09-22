import Foundation
import Testing
@testable import MultiModalKit

#if canImport(MultiModalKitTTS)
import TTSKit
@testable import MultiModalKitTTS

/// AC-291, AC-294, AC-295 for the neural voice (5a, piece 5; D-114
/// F-3 = A, F-4 = A, F-5 = A, F-6 = A): the vendor's own file set,
/// through the downloader, against the counting loopback server.
///
/// The real download is ~1.1 GB across 33 files in two repositories, and
/// two variants share one tree. These rows serve a handful of small
/// files at their declared sizes and watch the two things that tree
/// makes hard: that a download writes only ITS variant's six component
/// directories, and that a delete takes only those — leaving the other
/// variant's, and the tokenizer both of them share.
///
/// THE VENDOR'S LAYOUT, UNDER THE BENCH'S OWN ROOT. The paths below the
/// root are the vendor's and no test chooses them; the root itself is
/// redirected, so these rows never write into a person's real model
/// folders — this Mac has the 0.6B installed for real, and the first run
/// of this suite read it as the bench's own install.
@Suite("AC-291/294/295 · the neural voice through the downloader", .serialized, .timeLimit(.minutes(1)))
struct NeuralVoiceInstallTests {

    @Test("the plan is the VENDOR's file set, not a list written here")
    func thePlanIsTheVendorsFileSet() {
        let voice = NeuralVoice(variant: .qwen3TTS_0_6b)
        #expect(voice.catalog.patterns == TTSKitConfig(model: .qwen3TTS_0_6b).downloadPatterns,
                "asked of the vendor, so the file set cannot drift from what TTSKit loads")
        #expect(voice.catalog.versionDir == TTSKitConfig(model: .qwen3TTS_0_6b).versionDir)
        #expect(voice.catalog.patterns.count == TTSKitConfig.componentNames.count,
                "one glob per component — one quantisation each")
    }

    @Test("the variant's six directories arrive under one fraction; then installed")
    func theSixDirectoriesArriveUnderOneFraction() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        let seen = FractionWatcher()
        #expect(await !bench.voice.modelInstalled())

        try await bench.voice.download(progress: seen.record)

        let fractions = seen.fractions
        #expect(fractions == fractions.sorted(), "never decreasing: \(fractions)")
        #expect(fractions.last == 1.0 && fractions.filter { $0 == 1.0 }.count == 1, "1.0 once, last")
        #expect(await bench.voice.modelInstalled())
        #expect(bench.server.counts(for: bench.modelTreePath).requests == 1, "one request per repository")
        #expect(bench.server.counts(for: bench.tokenizerTreePath).requests == 1)
        #expect(bench.exists(component: "text_projector"), "each of the six is in place")
        #expect(bench.exists(component: "speech_decoder"))
        #expect(bench.tokenizerExists("tokenizer.json"), "and the shared tokenizer")
        #expect(!FileManager.default.fileExists(atPath: bench.voice.catalog.modelScratch.path),
                "the scratch was moved into place")
    }

    @Test("an installed variant reports one 1.0 and asks the server nothing")
    func anInstalledVariantAsksNothing() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        try await bench.voice.download()
        let seen = FractionWatcher()

        try await bench.voice.download(progress: seen.record)

        #expect(seen.fractions == [1.0])
        #expect(bench.server.counts(for: bench.modelTreePath).requests == 1, "not even a listing")
    }

    /// The tokenizer repository is hard-wired to one for every variant,
    /// so a second variant must not pay 11 MB for it again.
    @Test("a variant installed beside another does not fetch the shared tokenizer twice")
    func theSharedTokenizerIsFetchedOnce() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        try await bench.voice.download()
        let asked = bench.server.counts(for: bench.tokenizerFilePath("tokenizer.json")).requests
        #expect(asked == 1)

        let sibling = bench.voice(for: .qwen3TTS_1_7b)
        try await sibling.download()

        #expect(bench.server.counts(for: bench.tokenizerFilePath("tokenizer.json")).requests == 1,
                "the second variant found it already in the shared folder")
        #expect(await sibling.modelInstalled())
        #expect(await bench.voice.modelInstalled(), "and the first is untouched")
    }

    @Test("the size is known without the network: the measured variants, then this device's listing")
    func theSizeIsKnownWithoutTheNetwork() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        // The variants this library names, measured 2026-09-22 under the
        // vendor's own patterns (the live row re-reads them).
        #expect(NeuralVoice(variant: .qwen3TTS_0_6b).expectedDownloadBytes() == 1_102_450_874)
        #expect(NeuralVoice(variant: .qwen3TTS_1_7b).expectedDownloadBytes() == 2_179_559_521)

        try await bench.voice.download()

        #expect(NeuralVoiceListing.read(from: bench.voice.catalog.listingFile)?.totalBytes == bench.totalBytes,
                "and the listing this device made, for whatever the measured table does not name")
    }

    @Test("deleteModel removes this variant's six directories and leaves the other variant's")
    func deleteModelLeavesTheOtherVariant() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        try await bench.voice.download()
        let sibling = bench.voice(for: .qwen3TTS_1_7b)
        try await sibling.download()
        #expect(await bench.voice.modelInstalled())

        try await bench.voice.deleteModel()

        #expect(await !bench.voice.modelInstalled())
        #expect(!bench.exists(component: "text_projector"), "this variant's directories")
        #expect(await sibling.modelInstalled(), "the other variant: still installed")
        #expect(bench.tokenizerExists("tokenizer.json"),
                "and the SHARED tokenizer stays while a variant still needs it")
    }

    @Test("deleteModel takes the shared tokenizer once no variant is left")
    func deleteModelTakesTheTokenizerLast() async throws {
        let bench = try NeuralBench()
        defer { bench.tearDown() }
        try await bench.voice.download()
        #expect(bench.tokenizerExists("tokenizer.json"))

        try await bench.voice.deleteModel()

        #expect(!bench.tokenizerExists("tokenizer.json"),
                "nobody is left to need it — 11 MB a person would otherwise keep forever")
        #expect(NeuralVoiceListing.read(from: bench.voice.catalog.listingFile) == nil, "the listing went too")
    }

    @Test("a stopped transfer keeps its scratch and resumes; nothing is installed meanwhile")
    func aStoppedTransferKeepsItsScratch() async throws {
        let bench = try NeuralBench(weightBytes: 1_048_576)
        defer { bench.tearDown() }
        bench.server.hold(bench.modelFilePath("speech_decoder", NeuralBench.nestedFile), after: 131_072)
        let seen = FractionWatcher()

        let first = Task { try await bench.voice.download(progress: seen.record) }
        await bench.server.parkedConnection()
        await seen.fraction(atLeast: 0.05)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        #expect(await !bench.voice.modelInstalled(), "a partial is not an install")
        #expect(!bench.exists(component: "speech_decoder"), "and nothing of it is where the check looks")
        // The quantisation folder is the VENDOR's, read from its own
        // pattern — writing "W8A16" here would be this repo's oldest
        // mistake (SPEC §118), and the speech decoder's is not W8A16.
        let quant = NeuralBench.quantisation(of: "speech_decoder", in: TTSKitConfig(model: .qwen3TTS_0_6b))
        let resume = bench.voice.catalog.modelScratch
            .appending(path: "speech_decoder/\(bench.voice.catalog.versionDir)/\(quant)")
            .appending(path: NeuralBench.nestedFile + ".resume")
        #expect(FileManager.default.fileExists(atPath: resume.path), "F-4 = A: what can be resumed is kept")

        bench.server.release()
        try await bench.voice.download()

        let counts = bench.server.counts(for: bench.modelFilePath("speech_decoder", NeuralBench.nestedFile))
        #expect(counts.rangeRequests == 1, "resumed, not restarted")
        #expect(await bench.voice.modelInstalled())
    }
}

/// The real repositories, read — the pin that catches the day the
/// vendor re-converts a variant and `NeuralVoiceSizes` goes stale.
/// Opt-in (`MMK_LIVE_HUB=1`), so CI stays hermetic.
@Suite("AC-294 · the neural voice's measured variants, against the real repositories",
       .enabled(if: ProcessInfo.processInfo.environment["MMK_LIVE_HUB"] == "1",
                "set MMK_LIVE_HUB=1 to ask huggingface.co"),
       .timeLimit(.minutes(2)))
struct NeuralVoiceInstallLiveTests {
    @Test("each variant still costs what this library says it costs",
          arguments: [TTSModelVariant.qwen3TTS_0_6b, .qwen3TTS_1_7b])
    func theMeasuredSizesStillHold(variant: TTSModelVariant) async throws {
        let listed = try await NeuralVoice(variant: variant).catalog.list()
        #expect(listed.totalBytes == NeuralVoiceSizes.measured(for: variant),
                "\(variant): the repositories now hold \(listed.totalBytes) bytes — re-measure with today's date")
        #expect(listed.model.count == 30, "the vendor's patterns select one quantisation per component")
    }
}

// MARK: - the bench

/// A loopback Hub serving both variants' component files and the shared
/// tokenizer, and voices pointed at it.
struct NeuralBench {
    let server: LoopbackFileServer
    /// Qualified: TTSKit ships one of its own (`ArgmaxCore`).
    let downloader: MultiModalKit.ModelDownloader
    let voice: NeuralVoice
    let root: URL
    let totalBytes: Int64

    /// One compiled bundle per component, in the shape the vendor's
    /// install check really walks: `<quant>/<Name>.mlmodelc/coremldata.bin`,
    /// and BIGGER than 1 KB — the check treats a trivial file as the
    /// truncated download it usually is (the first run of this suite
    /// wrote exactly 1 024 bytes and was told, correctly, "not installed").
    static let componentFile = "Component.mlmodelc/coremldata.bin"
    static let nestedFile = "SpeechDecoder.mlmodelc/coremldata.bin"
    static let componentBytes = 2_048
    static let tokenizerFiles = ["config.json": 64, "tokenizer.json": 256, "tokenizer_config.json": 128]

    init(weightBytes: Int? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "neural-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "served"),
                                                withIntermediateDirectories: true)
        server = try LoopbackFileServer(directory: root.appending(path: "served"))
        downloader = MultiModalKit.ModelDownloader(
            configuration: .background(withIdentifier: "neural-bench.\(UUID().uuidString)"))
        let host = URL(string: "http://127.0.0.1:\(server.port)")!
        let source = NeuralVoiceSource(host: host)
        voice = NeuralVoice(variant: .qwen3TTS_0_6b, renderingOn: nil, lead: nil,
                            multiCodeDecoderMode: .fused, speechDecoderMode: .latencyOptimized,
                            temperature: nil, seed: nil, availableOnThisPlatform: true,
                            source: source, downloader: downloader, installRoot: root)
        var model = 0
        for variant in [TTSModelVariant.qwen3TTS_0_6b, .qwen3TTS_1_7b] {
            model += try Self.serveVariant(variant, under: root, weightBytes: weightBytes)
        }
        _ = model
        try Self.serveTokenizer(under: root)
        // This bench's 0.6B: six component files, one of them the big one.
        let sixth = weightBytes ?? 4_096
        totalBytes = Int64(5 * Self.componentBytes + sixth + Self.tokenizerFiles.values.reduce(0, +))
    }

    /// A second voice on the same bench, for the other variant.
    func voice(for variant: TTSModelVariant) -> NeuralVoice {
        NeuralVoice(variant: variant, renderingOn: nil, lead: nil,
                    multiCodeDecoderMode: .fused, speechDecoderMode: .latencyOptimized,
                    temperature: nil, seed: nil, availableOnThisPlatform: true,
                    source: NeuralVoiceSource(host: URL(string: "http://127.0.0.1:\(server.port)")!),
                    downloader: downloader, installRoot: root)
    }

    func tearDown() {
        server.stop()
        let downloader = downloader
        Task { await downloader.invalidate() }
        // Everything this bench wrote is under its own root, including
        // the vendor's folder layout — nothing of the person's own.
        try? FileManager.default.removeItem(at: root)
    }

    var modelTreePath: String { "api/models/argmaxinc/ttskit-coreml/tree/main/qwen3_tts" }
    var tokenizerTreePath: String { "api/models/Qwen/Qwen3-0.6B/tree/main" }

    func modelFilePath(_ component: String, _ file: String, variant: TTSModelVariant = .qwen3TTS_0_6b) -> String {
        let config = TTSKitConfig(model: variant)
        let quant = Self.quantisation(of: component, in: config)
        return "argmaxinc/ttskit-coreml/resolve/main/qwen3_tts/\(component)/\(config.versionDir)/\(quant)/\(file)"
    }

    func tokenizerFilePath(_ name: String) -> String { "Qwen/Qwen3-0.6B/resolve/main/\(name)" }

    /// This variant's component directory, in place.
    func exists(component: String, variant: TTSModelVariant = .qwen3TTS_0_6b) -> Bool {
        let catalog = voice(for: variant).catalog
        let directory = catalog.familyFolder.appending(path: component).appending(path: catalog.versionDir)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == false
    }

    func tokenizerExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: voice.catalog.tokenizerFolder.appending(path: name).path)
    }

    /// The quantisation folder the vendor's own pattern names for this
    /// component — parsed from the pattern, never written down here.
    static func quantisation(of component: String, in config: TTSKitConfig) -> String {
        for pattern in config.downloadPatterns {
            let parts = pattern.split(separator: "/").map(String.init)
            if parts.count >= 4, parts[1] == component { return parts[3] }
        }
        return ""
    }

    /// One variant's six component files, served at the paths the
    /// vendor's patterns select.
    private static func serveVariant(_ variant: TTSModelVariant, under root: URL, weightBytes: Int?) throws -> Int {
        let config = TTSKitConfig(model: variant)
        var rows: [String] = []
        var total = 0
        for component in TTSKitConfig.componentNames {
            let quant = quantisation(of: component, in: config)
            let file = component == "speech_decoder" ? nestedFile : componentFile
            let bytes = component == "speech_decoder" ? (weightBytes ?? 4_096) : componentBytes
            let path = "qwen3_tts/\(component)/\(config.versionDir)/\(quant)/\(file)"
            rows.append(#"{"type":"file","oid":"x","size":\#(bytes),"path":"\#(path)"}"#)
            // A file of the quantisation this configuration does NOT
            // load: the vendor's patterns must leave it out.
            let other = "qwen3_tts/\(component)/\(config.versionDir)/OTHER-QUANT/\(file)"
            rows.append(#"{"type":"file","oid":"x","size":999999,"path":"\#(other)"}"#)
            try serve(root, "argmaxinc/ttskit-coreml/resolve/main/\(path)", bytes: bytes)
            total += bytes
        }
        try appendTree(root, "api/models/argmaxinc/ttskit-coreml/tree/main/qwen3_tts", rows: rows)
        return total
    }

    private static func serveTokenizer(under root: URL) throws {
        let rows = tokenizerFiles.sorted { $0.key < $1.key }.map { name, bytes in
            #"{"type":"file","oid":"x","size":\#(bytes),"path":"\#(name)"}"#
        }
        try appendTree(root, "api/models/Qwen/Qwen3-0.6B/tree/main", rows: rows)
        for (name, bytes) in tokenizerFiles {
            try serve(root, "Qwen/Qwen3-0.6B/resolve/main/\(name)", bytes: bytes)
        }
    }

    /// Both variants share one tree endpoint, so its rows accumulate.
    private static func appendTree(_ root: URL, _ path: String, rows: [String]) throws {
        let file = root.appending(path: "served/\(path)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var all = rows
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.dropFirst().dropLast()
            if !trimmed.isEmpty { all = [String(trimmed)] + rows }
        }
        try Data(("[" + all.joined(separator: ",") + "]").utf8).write(to: file)
    }

    private static func serve(_ root: URL, _ name: String, bytes: Int) throws {
        let file = root.appending(path: "served/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        for index in stride(from: 0, to: bytes, by: 4_096) { data[index] = UInt8(truncatingIfNeeded: index / 4_096) }
        try data.write(to: file)
    }
}
#endif
