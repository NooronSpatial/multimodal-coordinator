import Foundation
import Synchronization
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

    /// A MANIFEST IS READ OFF DISK, so its numbers are not the library's.
    /// `totalBytes` was `files.values.reduce(0, +)`, which TRAPS on
    /// overflow: the 4v review wrote two `Int64.max` entries into a
    /// `manifest.json`, read it back — the decode printed both numbers —
    /// and the process died on the sum, "exited with unexpected signal
    /// code 5". The weights directory defaults to the app's Documents,
    /// which `LocalMind`'s own doc comment describes as a place "a person
    /// can also drop the folder by hand over USB", so the bytes in that
    /// file are not fully under this library's control. A saturating sum
    /// is the honest answer: a total this large is "more than can be
    /// counted", never a termination (AC-241's rule).
    @Test("a manifest whose numbers overflow Int64 saturates, and never traps")
    func totalBytesSaturatesInsteadOfTrapping() {
        #expect(InstallManifest(files: ["a.safetensors": .max, "b.safetensors": .max]).totalBytes == .max)
        #expect(InstallManifest(files: ["a.safetensors": .min, "b.safetensors": .min]).totalBytes == .min)
        #expect(InstallManifest(files: ["a.safetensors": 32, "b.safetensors": 64]).totalBytes == 96)
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

    /// THE SAME LINE, THE OTHER WAY. The NaN row above fixed the FRACTION;
    /// the EXPECTED total could still kill the process. `Double(Int64.max)`
    /// rounds UP to 2^63, so `Double(total) * 1.0` is one ulp past what
    /// `Int64` can hold and the conversion traps — the 4v review ran
    /// `at(fraction: 1.0, bytesExpected: .max)` against the shipped public
    /// function and the test process died: "Double value cannot be
    /// converted to Int64 because the result would be greater than
    /// Int64.max", signal 5. The total is read from a `manifest.json` on
    /// disk (`download(reporting:)` hands `expectedBytes()` straight to
    /// this function), so it is an INPUT, not a constant this library
    /// controls. Received is never more than expected, which is also the
    /// only honest answer.
    @Test("an expected total at the edge of Int64 is not a trap")
    func aHugeExpectedTotalIsNotATrap() {
        #expect(InstallProgress.at(fraction: 1, bytesExpected: .max).bytesReceived == .max)
        #expect(InstallProgress.at(fraction: 0.5, bytesExpected: .max).bytesReceived
                == Int64((Double(Int64.max) * 0.5).rounded(.down)))
        #expect(InstallProgress.at(fraction: 0, bytesExpected: .max).bytesReceived == 0)
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

    /// THE DOOR ASKS ONE QUESTION, and this is the row the second 4v
    /// review found missing. The reply door used to add a memory claim
    /// the load door did not — `MindNeeds(memoryBytes:
    /// estimatedWorkingSetBytes())` — an asymmetry no AC asked for and no
    /// test could see: `MemoryHeadroomReader.read()` is
    /// `.unavailable(.noMemoryLimitOnThisPlatform)` on a Mac, so
    /// `report.memoryHeadroomBytes` is nil here and the verdict's memory
    /// branch is dead in every row that runs on this machine.
    ///
    /// On a phone it was not dead, and it could close the door for good:
    /// the estimate only drops to 0 once the weights are RESIDENT, and
    /// they become resident inside `tokens` → `ensureModelLoaded()`, which
    /// a refused door never reaches. 2.3 GB of weights × 1.5 is 3.45 GB,
    /// and iOS kills this app near 3351 MB (INSTRUMENTS §27) — so a caller
    /// that never called the optional `prewarm()` was locked out
    /// permanently. The claim is gone: what the door needs is now a pure
    /// function of the report, and a test writes the report by hand.
    ///
    /// Whether a reply door should EVER claim an estimated working set is
    /// a fork for Ryad, not a thing this code decides — it is reported,
    /// not ruled. Until it is ruled the door asks what AC-238 asks.
    @Test("the door's needs are the platform's floor and NO memory claim")
    func theDoorClaimsNoMemory() {
        for platform in [Platform.iOS, .macOS] {
            let report = DeviceReport(platform: platform, os: OSVersion(major: 26),
                                      isSimulator: false, gpu: .available,
                                      memoryHeadroomBytes: 64 * 1024 * 1024,
                                      install: .installed)
            #expect(LocalMindModel.needs(for: report).floor == platform.libraryFloor)
            #expect(LocalMindModel.needs(for: report).memoryBytes == 0,
                    "a mind that makes no claim is never refused for memory")
        }
    }

    /// The row the review asked for by name: a first turn on a
    /// memory-tight phone must still reach the load. The second
    /// expectation is the trap itself, written down — the same report
    /// under the claim the door used to make is refused, and refused
    /// forever, because the load that would have made the claim
    /// unnecessary is on the far side of the door.
    @Test("a memory-tight phone that has not loaded yet still opens the door")
    func aMemoryTightPhoneStillOpens() {
        let phone = DeviceReport(platform: .iOS, os: OSVersion(major: 18),
                                 isSimulator: false, gpu: .available,
                                 memoryHeadroomBytes: 900 * 1024 * 1024,
                                 install: .installedUnverified)
        #expect(MindReadiness.verdict(for: phone, needs: LocalMindModel.needs(for: phone)) == nil,
                "the door opens, the load happens, and the real number is measured")
        let claimed = MindNeeds(floor: phone.platform.libraryFloor, memoryBytes: 3_450_000_000)
        #expect(MindReadiness.verdict(for: phone, needs: claimed)
                == .notEnoughMemory(needed: 3_450_000_000, available: 900 * 1024 * 1024),
                "the estimate the door used to claim refuses this phone — and nothing lifts it")
    }

    @Test("a verdict's words never say Simulator on a machine that is not one")
    func noSimulatorWordOnHardware() {
        let absent = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        let words = absent.readiness().map(String.init(describing:)) ?? ""
        #expect(!words.contains("Simulator"))
    }
}

// MARK: - the download's OWN half (AC-239, AC-240)

/// AC-239's central promise is the manifest a COMPLETE download writes,
/// and the second 4v review found it asserted by NO test: the only row
/// that called `download` exercised the early return and pinned that no
/// manifest was written (`downloadOnACompleteTreeIsANoOp`). Every
/// manifest in the rows above was written BY THE TEST. So the write, the
/// cancellation guard, the remove/move and AC-240's byte wiring were
/// carried by inspection alone — and SPEC §179 names "the manifest
/// written on a real download" in the definition of done.
///
/// The fetch is now a value with the Hub's as its default, so this suite
/// runs the REAL `download` — its guards, its wiring, its write — with a
/// fake fetch that writes a small tree instead of a network call.
/// Nothing public changed to make this possible.
///
/// 4x TURNED THAT VALUE INTO A PROTOCOL (AC-249, SPEC §181/3), because
/// Aura needs the same seam from outside the package. These rows kept
/// their shape: `FakeWeightsFetcher` wraps the closure they were written
/// with, so what they prove is unchanged.
@Suite("AC-239/AC-240 · what a download does after the bytes land", .serialized)
struct MLXDownloadTests {

    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The tree a fetch leaves behind, with known bytes.
    private static func tree(at directory: URL, weightBytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in [("config.json", 32), ("tokenizer.json", 64),
                              ("tokenizer_config.json", 16), ("model.safetensors", weightBytes)] {
            try Data(repeating: 0x2A, count: bytes).write(to: directory.appending(path: name))
        }
    }

    /// A fetch that writes its tree where the Hub would and hands back
    /// that path, reporting the fractions it is given.
    private static func fakeFetch(
        placing snapshot: URL, weightBytes: Int = 4096, reporting fractions: [Double] = [0.5, 1]
    ) -> FakeWeightsFetcher {
        FakeWeightsFetcher { _, _, report in
            try Self.tree(at: snapshot, weightBytes: weightBytes)
            for fraction in fractions { report(fraction) }
            return snapshot
        }
    }

    @Test("a complete download writes manifest.json listing every file at its byte count")
    func aCompleteDownloadWritesTheManifest() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")

        #expect(model.installState() == .absent, "nothing is there before the download")
        try await model.download(reporting: { _ in }, using: Self.fakeFetch(placing: snapshot))

        let manifest = try #require(InstallManifest.read(in: model.weights))
        #expect(manifest.files == ["config.json": 32, "tokenizer.json": 64,
                                   "tokenizer_config.json": 16, "model.safetensors": 4096],
                "every file the download left, at the bytes it left")
        #expect(model.installState() == .installed, "written by the code under test, not by the test")
        #expect(model.modelInstalled())
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false,
                "the snapshot was MOVED to the weights path, not copied")
    }

    /// AC-240's Hub half, end to end: "the Hub path reports its client's
    /// fraction plus the manifest's expected bytes". The client's fraction
    /// is a fraction of FILES; the only source of a byte total is the
    /// manifest an earlier install left — so this is the re-install after
    /// an `.incomplete`, which is the one case where the number exists.
    @Test("a re-install reports the client's fraction plus the OLD manifest's expected bytes")
    func theHubPathCarriesTheManifestsExpectedTotal() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        // An earlier install that died: a manifest saying 8192 bytes of
        // weights, and a file holding 1024 of them.
        try Self.tree(at: model.weights, weightBytes: 8192)
        try InstallManifest(listing: model.weights).write(in: model.weights)
        try Data(repeating: 0x2A, count: 1024)
            .write(to: model.weights.appending(path: "model.safetensors"))
        #expect(model.installState() == .incomplete(files: ["model.safetensors"]))
        let expected: Int64 = 32 + 64 + 16 + 8192

        let seen = Mutex<[InstallProgress]>([])
        let snapshot = base.appending(path: "snapshot")
        try await model.download(
            reporting: { progress in seen.withLock { $0.append(progress) } },
            using: Self.fakeFetch(placing: snapshot, weightBytes: 8192))

        #expect(seen.withLock { $0 } == [
            InstallProgress(fraction: 0.5, bytesReceived: expected / 2, bytesExpected: expected),
            InstallProgress(fraction: 1, bytesReceived: expected, bytesExpected: expected)
        ], "the client's fraction, the old manifest's total, and nothing invented")
        #expect(model.installState() == .installed, "and the new manifest replaced the old one")
    }

    @Test("a FIRST install invents no expected total — a fraction is all anyone knows")
    func aFirstInstallInventsNoTotal() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)

        let seen = Mutex<[InstallProgress]>([])
        try await model.download(
            reporting: { progress in seen.withLock { $0.append(progress) } },
            using: Self.fakeFetch(placing: base.appending(path: "snapshot"),
                                     reporting: [0.25]))
        #expect(seen.withLock { $0 } == [InstallProgress(fraction: 0.25, bytesReceived: nil,
                                                         bytesExpected: nil)])
    }

    /// THE HUB RETURNS EARLY ON CANCELLATION with a PARTIAL tree and no
    /// error — the whole reason `try Task.checkCancellation()` sits
    /// between the snapshot and the write. A manifest written from that
    /// tree would list the short files at their short sizes and call the
    /// install complete: the exact lie AC-239 exists to end. The guard had
    /// no test until the second review asked for one.
    ///
    /// The wait is an EVENT, not a sleep: the fake fetch says it has
    /// started, the test cancels, and only then does the fetch return —
    /// so the cancel is delivered before `completeInstall` is reached,
    /// every run.
    @Test("a cancelled download writes no manifest, and the partial tree is not moved")
    func aCancelledDownloadWritesNoManifest() async throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")
        let started = InstallSignals()
        let mayReturn = InstallSignals()

        let task = Task {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, _ in
                try Self.tree(at: snapshot, weightBytes: 1024)   // the PARTIAL tree
                started.send("fetching")
                _ = await mayReturn.heard("cancelled")
                return snapshot
            })
        }
        #expect(await started.heard("fetching"), "the fake fetch must run before the cancel")
        task.cancel()
        mayReturn.send("cancelled")

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(InstallManifest.read(in: model.weights) == nil,
                "a partial tree must never be blessed with a manifest")
        #expect(FileManager.default.fileExists(atPath: model.weights.path) == false,
                "and nothing was moved into the weights path")
        #expect(model.installState() == .absent)
    }
}

// The house wait `InstallSignals` moved to `MLXInstallDoubles.swift` when
// 4x gave three suites the same need for it. Same class, same comment.
