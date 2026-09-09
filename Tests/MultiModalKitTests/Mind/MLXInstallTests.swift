import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-239 (SPEC §175/6, Aura's L1): "installed" used to mean "a file
/// exists". Now a download writes `manifest.json` — every file and its
/// byte count — and `installState()` verifies existence AND size of
/// every listed file. Every row here runs in a temporary directory with
/// fake bytes: no weights, no network, no MLX.
@Suite("AC-239 · the install manifest: every file, every byte", .serialized)
struct MLXInstallStateTests {

    /// A fresh directory per test, removed afterwards.
    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The four files `modelInstalled()` has always required, with fake
    /// bytes — the sizes are what the manifest will remember.
    private static func fakeTree(in directory: URL) throws {
        for (name, bytes) in [("config.json", 32), ("tokenizer.json", 64),
                              ("tokenizer_config.json", 16), ("model.safetensors", 4096)] {
            try Data(repeating: 0x2A, count: bytes).write(to: directory.appending(path: name))
        }
    }

    @Test("a tree that matches its manifest is .installed")
    func matchingTreeIsInstalled() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.fakeTree(in: directory)
        try InstallManifest(listing: directory).write(in: directory)

        let model = LocalMindModel(weights: directory)
        #expect(model.installState() == .installed)
        #expect(model.modelInstalled())
    }

    @Test("one truncated file is .incomplete(files:) naming exactly that file")
    func truncatedFileIsIncomplete() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.fakeTree(in: directory)
        try InstallManifest(listing: directory).write(in: directory)
        // The download died at 1 KB of 4.
        try Data(repeating: 0x2A, count: 1024).write(to: directory.appending(path: "model.safetensors"))

        let model = LocalMindModel(weights: directory)
        #expect(model.installState() == .incomplete(files: ["model.safetensors"]))
        #expect(model.modelInstalled() == false, "a short file is not an install")
    }

    @Test("a missing listed file is .incomplete too, and names it")
    func missingListedFileIsIncomplete() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.fakeTree(in: directory)
        try InstallManifest(listing: directory).write(in: directory)
        try FileManager.default.removeItem(at: directory.appending(path: "tokenizer.json"))

        #expect(LocalMindModel(weights: directory).installState() == .incomplete(files: ["tokenizer.json"]))
    }

    @Test("files present but no manifest is .installedUnverified — the phones in the field")
    func noManifestIsUnverified() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.fakeTree(in: directory)

        let model = LocalMindModel(weights: directory)
        #expect(model.installState() == .installedUnverified)
        #expect(model.modelInstalled(), "they ran yesterday; a missing manifest is not a missing file")
    }

    @Test("an empty directory, or none at all, is .absent")
    func nothingIsAbsent() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(LocalMindModel(weights: directory).installState() == .absent)
        #expect(LocalMindModel(weights: directory.appending(path: "never-made")).installState() == .absent)
    }

    @Test("the safetensors alone, without the tokenizer's files, is .absent — offline-capable or nothing")
    func weightsWithoutTokenizerIsAbsent() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x2A, count: 4096).write(to: directory.appending(path: "model.safetensors"))
        #expect(LocalMindModel(weights: directory).installState() == .absent)
    }

    /// A MANIFEST IS NOT A LICENCE. The manifest branch used to answer
    /// `shortfall.isEmpty ? .installed : .incomplete` and never asked the
    /// offline-capable question at all, so a tree holding nothing but
    /// `config.json` — plus a manifest written from that tree, which of
    /// course has no shortfall — reported `.installed`, `modelInstalled()`
    /// returned true, the readiness verdict was nil, and `download`'s
    /// `guard !modelInstalled()` then returned early FOREVER. The door
    /// opened and the failure moved into the vendor's load.
    ///
    /// It is reachable: the snapshot asks for `*.safetensors, *.json,
    /// *.txt`, so a repo shipping `.bin`/`.gguf` weights, or a
    /// sentencepiece-only tokenizer, lands a tree the manifest then
    /// declares complete. Before 4v that tree was `false` and the door
    /// refused — the name-only check required all four files.
    ///
    /// The answer is `.absent`, the same word the no-manifest path already
    /// gives for the same tree (`weightsWithoutTokenizerIsAbsent`): one
    /// tree, one verdict, manifest or not — and `.absent` is the verdict a
    /// person can act on, because a download fixes it.
    @Test("a manifest over a tree that cannot answer offline is .absent, not .installed")
    func aCompleteManifestOverAnIncapableTreeIsAbsent() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Everything the snapshot brought: one JSON, no weights, no
        // tokenizer — and a manifest written from exactly that.
        try Data(repeating: 0x2A, count: 32).write(to: directory.appending(path: "config.json"))
        try InstallManifest(listing: directory).write(in: directory)

        let model = LocalMindModel(weights: directory)
        #expect(model.installState() == .absent, "a manifest with no shortfall is not an install")
        #expect(model.modelInstalled() == false, "offline-capable or nothing — Whisper's rule")
        #expect(model.readiness() != nil, "the door must still refuse this tree")
    }

    @Test("the manifest lists every regular file with its bytes, and never itself")
    func manifestListsEveryFile() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.fakeTree(in: directory)
        let manifest = try InstallManifest(listing: directory)
        try manifest.write(in: directory)
        #expect(manifest.files == ["config.json": 32, "tokenizer.json": 64,
                                   "tokenizer_config.json": 16, "model.safetensors": 4096])
        #expect(try InstallManifest(listing: directory).files == manifest.files,
                "listing again after the write must not count manifest.json")
        #expect(InstallManifest.read(in: directory) == manifest)
        #expect(manifest.totalBytes == 32 + 64 + 16 + 4096)
    }

    /// Only a DOWNLOAD writes a manifest. A pre-4v tree that is already
    /// complete is left as it is: `download` returns before touching the
    /// network, and does not invent a manifest for files it did not
    /// fetch — that would be a claim of bytes it never checked.
    @Test("download on a complete pre-4v tree touches nothing and writes no manifest")
    func downloadOnACompleteTreeIsANoOp() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let weights = directory.appending(path: "Fake-Model")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Self.fakeTree(in: weights)

        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: directory)
        #expect(model.weights == weights)
        try await model.download(reporting: { _ in Issue.record("no download, no progress") })
        #expect(InstallManifest.read(in: weights) == nil)
        #expect(model.installState() == .installedUnverified)
    }
}

/// AC-240 (Aura's L4): progress carries bytes when they are KNOWN. The
/// Hub client reports a fraction of FILES, not bytes; the manifest of a
/// previous install is the only source of an expected byte count. The
/// arithmetic is a pure function, and its fractions are binary-exact.
@Suite("AC-240 · install progress carries bytes when they are known")
struct MLXInstallProgressTests {

    @Test("with an expected total, received is fraction × expected")
    func bytesFromAKnownTotal() {
        let quarter = InstallProgress.at(fraction: 0.25, bytesExpected: 4096)
        #expect(quarter == InstallProgress(fraction: 0.25, bytesReceived: 1024, bytesExpected: 4096))
        let half = InstallProgress.at(fraction: 0.5, bytesExpected: 4096)
        #expect(half.bytesReceived == 2048)
    }

    @Test("without an expected total, both byte fields are nil — a fraction is all that is known")
    func noTotalNoBytes() {
        let progress = InstallProgress.at(fraction: 0.5, bytesExpected: nil)
        #expect(progress == InstallProgress(fraction: 0.5, bytesReceived: nil, bytesExpected: nil))
    }

    @Test("the fraction is clamped to 0…1 — the client has reported outside it")
    func fractionIsClamped() {
        #expect(InstallProgress.at(fraction: 1.5, bytesExpected: 4096).fraction == 1)
        #expect(InstallProgress.at(fraction: -0.25, bytesExpected: nil).fraction == 0)
        #expect(InstallProgress.at(fraction: .infinity, bytesExpected: 4096).fraction == 1)
        #expect(InstallProgress.at(fraction: -.infinity, bytesExpected: 4096).fraction == 0)
    }

    /// THE CLAMP THAT DID NOT CLAMP. `min(max(x, 0), 1)` passes NaN
    /// straight through — both comparisons against NaN are false, so
    /// each call returns the NaN operand — and the next line asked
    /// `Int64` for it. The 4v review ran exactly this row against the
    /// shipped public function and KILLED the test process:
    /// "Double value cannot be converted to Int64 because it is either
    /// infinite or NaN", signal 5. ±infinity was always clamped; only
    /// NaN escaped, and the doc-comment above `at` promised it did not.
    /// A public function in the milestone whose AC-241 exists to remove
    /// caller-reachable terminations must not add one.
    @Test("a NaN fraction is 0, never a trap")
    func nanIsZeroNeverATrap() {
        #expect(InstallProgress.at(fraction: .nan, bytesExpected: 4096)
                == InstallProgress(fraction: 0, bytesReceived: 0, bytesExpected: 4096))
        #expect(InstallProgress.at(fraction: .nan, bytesExpected: nil)
                == InstallProgress(fraction: 0, bytesReceived: nil, bytesExpected: nil))
    }
}

/// THE DOOR (AC-238's wiring, SPEC §175/5): the real source no longer
/// speaks in its own three strings — it asks `MindReadiness.verdict` over
/// a `DeviceReport` this machine fills, and throws `ReplyFailure.unavailable`
/// with the verdict. Runs on EVERY machine: the verdict for an absent
/// model depends on whether MLX can run here, and the test says which.
@Suite("AC-238 wiring · the MLX door throws the typed verdict")
struct MLXDoorTests {

    /// On a Mac with the shader library the first thing wrong is the
    /// weights; without it, the GPU comes first — the order is the
    /// contract, and this machine decides which row it is on.
    private static var expectedForAbsentWeights: MindUnavailable {
        MLXRuntime.isAvailable ? .weightsAbsent : .deviceCannotRun(.noGPU)
    }

    @Test("an absent model's verdict is typed, and the door throws it as ReplyFailure.unavailable")
    func theDoorThrowsTheVerdict() async {
        let absent = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        #expect(absent.readiness() == Self.expectedForAbsentWeights)

        let source = MLXTokenSource(model: absent, instructions: nil, maxTokens: 8)
        #expect(source.unavailable == .unavailable(Self.expectedForAbsentWeights))

        let mind = MLXReplyGenerator(model: absent)
        await #expect(throws: ReplyFailure.unavailable(Self.expectedForAbsentWeights)) {
            _ = try await mind.openReply(to: "hello?")
        }
    }

    @Test("the working-set estimate is 0 for absent weights — no claim on a number we do not have")
    func noWeightsNoMemoryClaim() {
        let absent = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        #expect(absent.estimatedWorkingSetBytes() == 0)
    }

    @Test("the working-set estimate is the safetensors bytes × 1.5 — the measured phone peaks")
    func estimateFollowsTheWeightsOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-estimate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 4096).write(to: directory.appending(path: "model.safetensors"))
        try Data(repeating: 0, count: 2048).write(to: directory.appending(path: "model-2.safetensors"))
        try Data(repeating: 0, count: 100_000).write(to: directory.appending(path: "tokenizer.json"))

        #expect(LocalMindModel(weights: directory).estimatedWorkingSetBytes() == 6144 + 3072,
                "the tokenizer's bytes are not weights and do not count")
    }

    /// THE RESIDENCY EXEMPTION, in both directions — the 4v review found
    /// it asserted in neither. A model whose weights are already loaded
    /// makes NO memory claim: the headroom the report measures has
    /// already paid for those bytes, so refusing a model that is loaded
    /// and answering, for memory it is already holding, would be a lie
    /// about this machine. `retire()` gives the claim back, because it
    /// gives the bytes back.
    ///
    /// The mirror is written by the actor after every load and every
    /// retire; a test reaches it through `@testable` and sets it by hand,
    /// because a real load needs 2 GB of weights and a GPU while the
    /// BRANCH needs neither. `retire()` here is the real method.
    @Test("a RESIDENT model claims no memory, and retire() gives the claim back")
    func aResidentModelClaimsNoMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-resident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 4096).write(to: directory.appending(path: "model.safetensors"))

        let model = LocalMindModel(weights: directory)
        #expect(model.estimatedWorkingSetBytes() == 4096 + 2048, "not resident: the estimate is paid")
        model.resident.withLock { $0 = true }
        #expect(model.estimatedWorkingSetBytes() == 0,
                "resident weights are already paid for; claiming them twice would refuse a live model")
        await model.retire()
        #expect(model.estimatedWorkingSetBytes() == 4096 + 2048,
                "retire gave the bytes back, so the claim comes back with them")
    }

    @Test("a verdict's words never say Simulator on a machine that is not one")
    func noSimulatorWordOnHardware() {
        let absent = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        let words = absent.readiness().map(String.init(describing:)) ?? ""
        #expect(!words.contains("Simulator"))
    }
}
