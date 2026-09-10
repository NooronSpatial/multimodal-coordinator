import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-247 / AC-248 / AC-249 / AC-250 (SPEC §181/2, 3, 5 — Aura's L3, L5,
/// L7), and D-106's F-2 = A.
///
/// A download that stops must leave nothing pretending. F-2 = A rules
/// that the partial tree is DELETED rather than kept for a resume:
/// simple, provable, and `installState()` cannot lie. The cost is that a
/// person who cancels at 90% pays again, and B — keep and resume — is
/// named as a later milestone for someone who can test it on a train.
///
/// The seam these rows drive is `WeightsFetching`, public since AC-249,
/// because the complete-install row is the one Aura copies for its
/// download screen.
@Suite("AC-247/248/249/250 · a download that stops, and one that finishes", .serialized)
struct MLXInstallSeamTests {

    // MARK: AC-249 — the row Aura copies

    /// FOUR SMALL FILES, A TEMPORARY DIRECTORY, AND NO NETWORK. This is
    /// the whole of AC-249: a caller's own fake, conforming to the public
    /// protocol, drives a real install — progress reported, manifest
    /// written, state `.installed` — with none of this library's Hub code
    /// in the path.
    ///
    /// The fractions are binary-exact quarters, so the expected progress
    /// is an equality and not an approximation.
    @Test("a caller's fake drives a complete install, with progress and a manifest")
    func aCallersFakeDrivesACompleteInstall() async throws {
        let base = try InstallScratch.directory("seam")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")
        let seen = Mutex<[InstallProgress]>([])

        #expect(model.installState() == .absent, "nothing is there before the download")
        try await model.download(
            reporting: { progress in seen.withLock { $0.append(progress) } },
            using: FakeWeightsFetcher { _, _, report in
                try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
                for (fraction, file) in [(0.25, "config.json"), (0.5, "tokenizer.json"),
                                         (0.75, "tokenizer_config.json"), (1.0, "model.safetensors")] {
                    let bytes = file == "model.safetensors" ? 4096 : 32
                    try Data(repeating: 0x2A, count: bytes)
                        .write(to: snapshot.appending(path: file))
                    report(fraction)
                }
                return snapshot
            })

        #expect(seen.withLock { $0.map(\.fraction) } == [0.25, 0.5, 0.75, 1],
                "the caller's fractions, reported as they came")
        #expect(seen.withLock { $0.allSatisfy { $0.bytesExpected == nil } },
                "a FIRST install invents no total — AC-240's rule, unchanged by 4x")
        let manifest = try #require(InstallManifest.read(in: model.weights))
        #expect(manifest.files == ["config.json": 32, "tokenizer.json": 32,
                                   "tokenizer_config.json": 32, "model.safetensors": 4096])
        #expect(model.installState() == .installed)
    }

    // MARK: AC-247 — the cancel

    /// The fake yields control after the SECOND file, exactly as AC-247
    /// asks. The wait is an EVENT, not a sleep: the fetch says it has
    /// written two files, the test cancels, and only then is the fetch
    /// allowed to return — so the cancel is delivered before the install
    /// is completed, every run.
    ///
    /// F-2 = A is the second half of the row: the partial snapshot is
    /// GONE from disk, not merely unblessed by a manifest.
    @Test("a cancel after the second file leaves .absent and deletes the partial tree")
    func aCancelDeletesThePartialTree() async throws {
        let base = try InstallScratch.directory("cancel")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")
        let twoFiles = InstallSignals()
        let mayReturn = InstallSignals()

        let task = Task {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, report in
                try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
                for file in ["config.json", "tokenizer.json"] {
                    try Data(repeating: 0x2A, count: 32).write(to: snapshot.appending(path: file))
                }
                report(0.5)
                twoFiles.send("two files")
                _ = await mayReturn.heard("cancelled")
                return snapshot
            })
        }
        #expect(await twoFiles.heard("two files"), "the fake must reach the second file first")
        task.cancel()
        mayReturn.send("cancelled")

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.installState() == .absent, "never .installed, never .installedUnverified")
        #expect(FileManager.default.fileExists(atPath: model.weights.path) == false)
        #expect(FileManager.default.fileExists(atPath: snapshot.path) == false,
                "F-2 = A: the partial tree is deleted, so installState() cannot lie")
    }

    // MARK: AC-248 — the throw

    /// A fetch that throws leaves the same nothing, and the error reaches
    /// the caller TYPED. `.fetchFailed` carries the fetcher's own words
    /// verbatim, the shape D-103's F-3 = A ruled for `ReplyFailure`: the
    /// words are still there for a screen, and the case is there for a
    /// switch.
    @Test("a fetch that throws leaves .absent, and the error is typed and switchable")
    func aThrownFetchLeavesNothing() async throws {
        let base = try InstallScratch.directory("throw")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")

        let failure = await #expect(throws: InstallFailure.self) {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, _ in
                try InstallScratch.tree(at: snapshot, weightBytes: 1024)   // the PARTIAL tree
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
        if case .fetchFailed(let words)? = failure {
            #expect(!words.isEmpty, "the fetcher's words survive, verbatim")
        } else {
            Issue.record("a failed fetch must arrive as .fetchFailed, not \(String(describing: failure))")
        }
        #expect(model.installState() == .absent)
        #expect(FileManager.default.fileExists(atPath: model.weights.path) == false)
    }

    // MARK: the guard — deleting a tree is destructive

    /// NEVER A CALLER'S WEIGHTS. Deleting a directory is the one thing in
    /// this file that can lose somebody's 2.3 GB, so the rule is written
    /// as narrowly as it can be: the download removes the weights tree
    /// only when THIS download created it.
    ///
    /// This row is the dangerous case — a tree that was already there,
    /// left `.incomplete` by an earlier attempt, and a re-download that
    /// fails. Its bytes are the caller's, not ours, and they survive.
    @Test("a failed re-download never deletes a tree it did not create")
    func aFailedRedownloadKeepsWhatWasAlreadyThere() async throws {
        let base = try InstallScratch.directory("keep")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        // An earlier install that died: a manifest promising 8192 bytes
        // of weights over a file holding 1024 of them.
        try InstallScratch.tree(at: model.weights, weightBytes: 8192)
        try InstallManifest(listing: model.weights).write(in: model.weights)
        try Data(repeating: 0x2A, count: 1024)
            .write(to: model.weights.appending(path: "model.safetensors"))
        #expect(model.installState() == .incomplete(files: ["model.safetensors"]))

        await #expect(throws: InstallFailure.self) {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
        #expect(model.installState() == .incomplete(files: ["model.safetensors"]),
                "the caller's partial bytes are still theirs — and the state still cannot lie")
    }

    /// THE RACE THE REENTRANCY LAW EXISTS FOR, written as a row because
    /// the guard that stops it is invisible otherwise.
    ///
    /// "Was the tree already there?" is read BEFORE the fetch, and an
    /// actor interleaves at every await. Two downloads on the same model
    /// both pass `guard !modelInstalled()` over an empty directory; if the
    /// slower one then fails, the answer it read is stale, and deleting on
    /// it would throw away the install the faster one had just finished.
    ///
    /// The order here is EVENTS, not timing: the slow download reaches its
    /// fetcher and waits there; the fast one runs to completion; only then
    /// is the slow one allowed to fail.
    @Test("a download that fails LATE never deletes the install another one just finished")
    func aLateFailureNeverDeletesAFinishedInstall() async throws {
        let base = try InstallScratch.directory("race")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let slowStarted = InstallSignals()
        let fastFinished = InstallSignals()

        let slow = Task {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, _ in
                slowStarted.send("waiting")
                _ = await fastFinished.heard("installed")
                throw CocoaError(.fileWriteOutOfSpace)
            })
        }
        #expect(await slowStarted.heard("waiting"), "the slow download must be parked in its fetch")

        try await model.download(reporting: { _ in },
                                 using: RecordingInstallSource(placing: base.appending(path: "fast")))
        #expect(model.installState() == .installed)
        fastFinished.send("installed")

        await #expect(throws: InstallFailure.self) { try await slow.value }
        #expect(model.installState() == .installed,
                "the stale answer is re-checked on the disk: a complete install is never deleted")
    }

    /// A COMPLETE install is protected one step earlier still: the
    /// download's own `guard !modelInstalled()` returns before a fetcher
    /// is ever asked for anything, so the deletion path is not merely
    /// guarded — it is unreachable. The recorder proves the fetcher was
    /// never called.
    @Test("an existing complete install survives a later re-download, untouched")
    func aCompleteInstallSurvivesAReDownload() async throws {
        let base = try InstallScratch.directory("complete")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        try InstallScratch.tree(at: model.weights)
        try InstallManifest(listing: model.weights).write(in: model.weights)
        #expect(model.installState() == .installed)
        let before = try InstallManifest.listing(of: model.weights)

        let source = RecordingInstallSource()
        try await model.download(reporting: { _ in }, using: source)

        #expect(source.calls.isEmpty, "the fetcher was never asked — the guard returned first")
        #expect(model.installState() == .installed)
        #expect(try InstallManifest.listing(of: model.weights) == before, "every byte still there")
    }

    // MARK: AC-250 — the backup flag that survives

    /// L7: the weights are a re-downloadable cache, and a 2.3 GB cache in
    /// a person's iCloud backup is a bill they did not agree to. The flag
    /// must therefore be re-applied after EVERY download, not only at
    /// creation — a `completeInstall` that moves a fresh snapshot into
    /// place is a new directory, and a new directory carries no flag.
    ///
    /// The re-download here is a REPAIR, because that is the only way one
    /// happens: `download` returns early on a complete tree, so the row
    /// truncates a file first — which is also the real case, an install
    /// that came back `.incomplete` and is being fixed.
    @Test("the backup flag is set by a download, and restored by the next one")
    func theBackupFlagSurvivesAReDownload() async throws {
        let base = try InstallScratch.directory("backup")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let source = RecordingInstallSource(placing: base.appending(path: "snapshot"))

        try await model.download(reporting: { _ in }, using: source)
        #expect(model.installState() == .installed)
        #expect(InstallScratch.excludedFromBackup(model.weights),
                "a download marks the weights excluded from backup")

        try InstallScratch.clearBackupExclusion(model.weights)
        #expect(InstallScratch.excludedFromBackup(model.weights) == false, "the flag is really gone")
        // Make the tree `.incomplete` so the download's guard lets a
        // second one through, the way a repair really reaches this path.
        try Data(repeating: 0x2A, count: 8)
            .write(to: model.weights.appending(path: "model.safetensors"))
        #expect(model.installState() == .incomplete(files: ["model.safetensors"]))

        try await model.download(reporting: { _ in }, using: source)
        #expect(model.installState() == .installed)
        #expect(InstallScratch.excludedFromBackup(model.weights),
                "AC-250: re-applied after EVERY download, not only at creation")
    }
}
