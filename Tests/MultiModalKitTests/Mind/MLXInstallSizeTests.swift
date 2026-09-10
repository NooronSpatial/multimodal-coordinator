import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-245 / AC-246 (SPEC §181/1, Aura's L2): "this needs 2.3 GB", said
/// BEFORE the first byte moves.
///
/// Aura cannot offer a 2.3 GB download that a person pays for while the
/// library's only honest answer is "I will tell you when it has
/// arrived". The size IS knowable in advance — the Hub lists a repo's
/// file names and a HEAD gives each file's size — so `expectedInstall()`
/// asks, and says in its name that it asks over the network.
///
/// Every row here runs against a FAKE metadata source. The real number
/// for the real repo is measured once and written into INSTRUMENTS with
/// its date, because it drifts the day the model is re-quantised.
@Suite("AC-245/AC-246 · the size, before anything is fetched", .serialized)
struct MLXInstallSizeTests {

    /// What a repo listing looks like when it is NOT just the files this
    /// library wants: a second copy of the weights in another format, a
    /// readme, and a licence. The download's glob takes four of these six.
    private static let repoListing: [InstallSize.FileSize] = [
        .init(name: "config.json", bytes: 32),
        .init(name: "tokenizer.json", bytes: 64),
        .init(name: "tokenizer_config.json", bytes: 16),
        .init(name: "model.safetensors", bytes: 4096),
        .init(name: "pytorch_model.bin", bytes: 1_000_000),
        .init(name: "README.md", bytes: 2048)
    ]

    /// THE NUMBER MUST BE ABOUT THE FILES THE DOWNLOAD FETCHES, which is
    /// the whole of AC-245. A size that summed everything the repo holds
    /// would be a true number about the wrong set — and `pytorch_model.bin`
    /// is a megabyte of exactly that lie, since Qwen-shaped repos really
    /// do carry a second copy of their weights.
    ///
    /// The glob is passed to the seam AND re-applied to what comes back:
    /// the seam is a caller's to fake, and a fake that ignores the glob
    /// must not be able to make this number a lie.
    @Test("the size sums exactly the files the download's glob would fetch")
    func theSizeIsTheDownloadsOwnFileSet() async throws {
        let model = LocalMindModel(repoID: "nobody/Fake-Model",
                                   in: FileManager.default.temporaryDirectory)
        let source = RecordingInstallSource(answering: Self.repoListing)

        let size = try await model.expectedInstall(asking: source.sizing)

        #expect(size.files == [
            InstallSize.FileSize(name: "config.json", bytes: 32),
            InstallSize.FileSize(name: "model.safetensors", bytes: 4096),
            InstallSize.FileSize(name: "tokenizer.json", bytes: 64),
            InstallSize.FileSize(name: "tokenizer_config.json", bytes: 16)
        ], "sorted by name, and the .bin and the README are not part of this download")
        #expect(size.downloadBytes == 32 + 4096 + 64 + 16)
        #expect(size.onDiskBytes == size.downloadBytes,
                "nothing is repacked: the snapshot is moved into place as it arrived")
    }

    /// AC-246, the sharp one: asking the size must not start a download.
    ///
    /// The recorder answers the size question and is ALSO a
    /// `WeightsFetching`, so the second half of this row shows it
    /// recording a fetch when one really happens. Without that half, "no
    /// fetch was recorded" would only say the fake was never wired up.
    @Test("asking for the size fetches nothing — and the same recorder DOES record a fetch")
    func askingTheSizeDownloadsNothing() async throws {
        let base = try InstallScratch.directory("size")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let source = RecordingInstallSource(answering: Self.repoListing,
                                            placing: base.appending(path: "snapshot"))

        _ = try await model.expectedInstall(asking: source.sizing)

        #expect(source.calls == [.sizes("nobody/Fake-Model")],
                "one metadata question, and no download")
        #expect(model.installState() == .absent, "nothing landed")
        #expect(FileManager.default.fileExists(atPath: model.weights.path) == false,
                "and the weights directory was not even created")

        try await model.download(reporting: { _ in }, using: source)
        #expect(source.calls == [.sizes("nobody/Fake-Model"), .fetch("nobody/Fake-Model")],
                "the recorder can see a fetch — so its absence above was evidence")
    }

    /// A model built with `init(weights:)` is bring-your-own: no repo, no
    /// question to ask. It throws what the DOWNLOAD throws for the same
    /// reason, so a caller has one case to handle, not two.
    @Test("a model with no repo throws the same typed error the download throws")
    func noRepoMeansNoAnswer() async throws {
        let model = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        await #expect(throws: ReplyFailure.unavailable(.weightsAbsent)) {
            _ = try await model.expectedInstall()
        }
        await #expect(throws: ReplyFailure.unavailable(.weightsAbsent)) {
            try await model.download(reporting: { _ in })
        }
    }

    /// A SIZE NOBODY KNOWS IS NOT A SIZE. The Hub answers a HEAD with a
    /// size header, and when it does not, the honest reply is a throw —
    /// not a total that quietly leaves the 2 GB file out and tells a
    /// person the download is 112 kB.
    @Test("a file whose size the source cannot give reaches the caller as a typed error")
    func anUnknownSizeIsATypedThrow() async throws {
        let model = LocalMindModel(repoID: "nobody/Fake-Model",
                                   in: FileManager.default.temporaryDirectory)
        let source = RecordingInstallSource(
            failingWith: InstallFailure.sizeUnknown(file: "model.safetensors"))

        await #expect(throws: InstallFailure.sizeUnknown(file: "model.safetensors")) {
            _ = try await model.expectedInstall(asking: source.sizing)
        }
    }
}
