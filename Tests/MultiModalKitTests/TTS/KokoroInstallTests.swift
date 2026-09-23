import Foundation
import Testing
@testable import MultiModalKit

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

/// AC-291, AC-294, AC-295 for the Kokoro voice (5a, D-114 F-3 = A, F-5 = A,
/// F-6 = A): the smallest catalog — two files, two sizes — through the
/// downloader, against the counting loopback server.
///
/// The real files are 327 MB; these rows point `KokoroWeights.Source` at
/// two small files of the test's own, declared at their true sizes, so
/// every promise about the install is proved on real bytes over a real
/// socket without a third of a gigabyte. `.float32`, so the fp16 cast —
/// 4q's work, tested there — is not in the way: at fp32 the download IS
/// the model file.
@Suite("AC-291/294/295 · Kokoro through the downloader", .serialized, .timeLimit(.minutes(1)))
struct KokoroInstallTests {

    @Test("both files arrive under one fraction, never decreasing, 1.0 once; then it is installed")
    func bothFilesArriveUnderOneFraction() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let weights = try bench.kokoro(modelBytes: 300_000, voiceBytes: 30_000)
        let seen = FractionWatcher()
        #expect(!weights.isInstalled())

        try await weights.ensure(progress: seen.record)

        let fractions = seen.fractions
        #expect(fractions == fractions.sorted(), "never decreasing: \(fractions)")
        #expect(fractions.last == 1.0 && fractions.filter { $0 == 1.0 }.count == 1, "1.0 once, last")
        #expect(weights.isInstalled(), Comment(rawValue: weights.missingReport() ?? "installed"))
        #expect(bench.server.counts(for: "model.bin").requests == 1)
        #expect(bench.server.counts(for: "voice.bin").requests == 1)
    }

    @Test("an installed Kokoro says 1.0 once and asks the server nothing")
    func anInstalledKokoroAsksNothing() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let weights = try bench.kokoro(modelBytes: 40_000, voiceBytes: 4_000)
        try await weights.ensure()
        let seen = FractionWatcher()

        try await weights.ensure(progress: seen.record)

        #expect(seen.fractions == [1.0])
        #expect(bench.server.counts(for: "model.bin").requests == 1, "asking is free")
        #expect(bench.server.counts(for: "voice.bin").requests == 1)
    }

    /// The failure 4q's byte count exists for — a present, truncated
    /// file — is now repaired by the same rule: the downloader treats a
    /// wrong-sized file as not there, fetches THAT file, and leaves the
    /// good one alone.
    @Test("a truncated download is fetched again, alone")
    func aTruncatedDownloadIsFetchedAgainAlone() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let weights = try bench.kokoro(modelBytes: 40_000, voiceBytes: 4_000)
        try await weights.ensure()
        try Data(count: 100).write(to: weights.sourceFile)
        #expect(!weights.isInstalled(), "one file short is not installed")

        try await weights.ensure()

        #expect(weights.isInstalled())
        #expect(bench.server.counts(for: "model.bin").requests == 2, "the damaged one, again")
        #expect(bench.server.counts(for: "voice.bin").requests == 1, "the good one, never")
    }

    @Test("remove takes the downloads, the cast and the resume data, and leaves the app's folder")
    func removeTakesTheDownloadsAndLeavesTheAppsFolder() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let weights = try bench.kokoro(modelBytes: 40_000, voiceBytes: 4_000)
        try await weights.ensure()
        let stranger = weights.directory.appending(path: "notes.txt")
        try Data("the app's own".utf8).write(to: stranger)
        try Data(count: 8).write(to: weights.voiceFile.appendingPathExtension("resume"))
        #expect(weights.isInstalled())

        await weights.remove()

        #expect(!weights.isInstalled())
        #expect(!FileManager.default.fileExists(atPath: weights.sourceFile.path))
        #expect(!FileManager.default.fileExists(atPath: weights.voiceFile.path))
        #expect(!FileManager.default.fileExists(atPath: weights.voiceFile.appendingPathExtension("resume").path))
        #expect(FileManager.default.fileExists(atPath: stranger.path), "not ours, not touched")
        #expect(FileManager.default.fileExists(atPath: weights.directory.path), "the app's directory stays")
    }

    @Test("deleteModel retires the voice and removes the files; modelInstalled reads false")
    func deleteModelRetiresTheVoiceAndRemovesTheFiles() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let weights = try bench.kokoro(modelBytes: 40_000, voiceBytes: 4_000)
        try await weights.ensure()
        let voice = KokoroVoice(weights: weights)
        #expect(await voice.modelInstalled())

        try await voice.deleteModel()

        #expect(await !voice.modelInstalled())
        await #expect(throws: KokoroVoiceRetired.self, "retired means terminal (D-079)") {
            _ = try await voice.openUtterance()
        }
    }

    @Test("the download's size is known without the network: the two files' bytes")
    func theSizeIsKnownWithoutTheNetwork() throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        #expect(try bench.kokoro(modelBytes: 40_000, voiceBytes: 4_000).expectedDownloadBytes == 44_000)
        #expect(KokoroWeights.inApplicationSupport().expectedDownloadBytes == 327_637_491,
                "the Hub mirror's two files, as 4q measured them")
        let voice = KokoroVoice(weights: KokoroWeights.inApplicationSupport())
        #expect(voice.expectedDownloadBytes() == 327_637_491)
    }
}

extension DownloadBench {
    /// Kokoro's two files, served by this bench at the sizes declared.
    func kokoro(modelBytes: Int, voiceBytes: Int) throws -> KokoroWeights {
        try serve("model.bin", bytes: modelBytes)
        try serve("voice.bin", bytes: voiceBytes)
        let directory = root.appending(path: "Kokoro Weights", directoryHint: .isDirectory)
        return KokoroWeights(directory: directory, precision: .float32,
                             source: KokoroWeights.Source(modelURL: server.url(for: "model.bin"),
                                                          voiceURL: server.url(for: "voice.bin"),
                                                          modelBytes: Int64(modelBytes),
                                                          voiceBytes: Int64(voiceBytes)),
                             downloader: downloader)
    }
}
#endif
