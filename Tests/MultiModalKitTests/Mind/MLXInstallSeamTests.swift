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
    ///
    /// AND THE PARTIAL TREE IS ASSERTED GONE, which the first version of
    /// this row did not do. It wrote a real partial tree and then checked
    /// only `model.weights` — a path the tree was never at — so the
    /// biggest hole in the milestone was invisible to it: on a throw the
    /// library is handed NO path, and a fetcher that kept its bytes left
    /// them there forever while this row stayed green.
    ///
    /// Who deletes what, now: the library deletes what it can NAME (the
    /// weights tree it created, and the directory a fetch handed back);
    /// the FETCHER deletes what only it knows about, because a throw
    /// carries no path. So the fake here does what `HubWeightsFetcher`
    /// does — it runs the shipped cleanup on the shipped location — and
    /// this row proves that code, not a fake's good manners.
    @Test("a fetch that throws leaves .absent, and the error is typed and switchable")
    func aThrownFetchLeavesNothing() async throws {
        let base = try InstallScratch.directory("throw")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        // Where the Hub client really materialises this repo — not
        // `model.weights`, which is where it is MOVED to afterwards.
        let partial = HubWeightsFetcher.snapshotLocation(repoID: "nobody/Fake-Model", under: base)

        let failure = await #expect(throws: InstallFailure.self) {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { repoID, handedBase, _ in
                try InstallScratch.tree(at: partial, weightBytes: 1024)   // the PARTIAL tree
                // F-2 = A, the fetcher's half: a conformer that throws
                // takes its own leftovers with it.
                HubWeightsFetcher.discardPartialTree(repoID: repoID, under: handedBase)
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
        #expect(FileManager.default.fileExists(atPath: partial.path) == false,
                "F-2 = A: the partial tree is gone, so the next attempt really does begin at zero")
    }

    /// F-2 = A FOR THE FETCHER THIS LIBRARY SHIPS, which is the one that
    /// matters: every other row here drives a fake.
    ///
    /// The review that raised this had the arithmetic. `HubWeightsFetcher`
    /// hands the client `weights.deletingLastPathComponent()` as its
    /// download base, and the client materialises the repo at
    /// `base/models/<owner>/<name>` — nowhere near `model.weights`. On a
    /// dropped connection, a 429 or a full disk, nothing ever removed
    /// that, and the client's own per-file bookkeeping lives INSIDE it
    /// (`<tree>/.cache/huggingface/download`), so the next attempt resumed
    /// from the leftovers. That is option B, the rejected one — and a
    /// person's 2.3 GB that died at 90% sat in Documents forever.
    ///
    /// The path needs no guessing: the client names it itself. This row
    /// pins the two halves — the location is the client's own answer, and
    /// the cleanup takes that tree and NOTHING beside it.
    @Test("the shipped fetcher's cleanup deletes its own tree, and only its own")
    func theShippedFetchersCleanupIsBounded() throws {
        let base = try InstallScratch.directory("hub-cleanup")
        defer { try? FileManager.default.removeItem(at: base) }
        let repoID = "nobody/Fake-Model"
        let partial = HubWeightsFetcher.snapshotLocation(repoID: repoID, under: base)
        // Another model already living in the same base — this demo really
        // does keep Whisper's weights beside the mind's.
        let sibling = base.appending(path: "whisper-weights")

        #expect(partial.path.hasPrefix(base.path + "/"),
                "the tree the cleanup removes is under the base this download was given")
        try InstallScratch.tree(at: partial, weightBytes: 4096)
        try InstallScratch.tree(at: sibling)

        HubWeightsFetcher.discardPartialTree(repoID: repoID, under: base)

        #expect(FileManager.default.fileExists(atPath: partial.path) == false,
                "F-2 = A: the client's partial tree goes, resume bookkeeping and all")
        #expect(FileManager.default.fileExists(atPath: sibling.path),
                "and another model's weights in the same base are never touched")
        #expect(FileManager.default.fileExists(atPath: base.path), "nor is the base itself")
    }

    // MARK: the bound — a fetcher's returned path is not a licence

    /// NEVER THE WHOLE BASE. `WeightsFetching` is public since AC-249 and
    /// its doc says "put the files under `base` and hand back where you
    /// put them" — so a conformer that writes straight into `base` and
    /// returns `base` is reading it plainly, not abusing it. The default
    /// base is the app's Documents.
    ///
    /// A review probe did exactly that: the move into place failed (a
    /// directory cannot be moved into itself), the failure path deleted
    /// "the snapshot", and Documents went with it — including a sibling
    /// model this download had never touched.
    ///
    /// The delete is now bounded to what THIS download could have made: a
    /// strict descendant of the base, and never an ancestor of the weights
    /// tree. Anything else is left alone, the same reasoning the
    /// `wasAlreadyThere` guard already uses.
    @Test("a fetcher that hands back the download base never loses the base, or a sibling")
    func aFetcherThatReturnsTheBaseKeepsIt() async throws {
        let base = try InstallScratch.directory("bound")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let sibling = base.appending(path: "whisper-weights")
        try InstallScratch.tree(at: sibling)

        await #expect(throws: InstallFailure.self) {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, handedBase, report in
                try InstallScratch.tree(at: handedBase)   // straight into the base…
                report(1)
                return handedBase                          // …and handed back as the snapshot
            })
        }
        #expect(FileManager.default.fileExists(atPath: base.path),
                "the download base is never what a failure deletes")
        #expect(FileManager.default.fileExists(atPath: sibling.path),
                "and a model this download never touched keeps every byte")
    }

    // MARK: the late failure — a tree that lies is not left standing

    /// A FAILURE AFTER THE MOVE, which is the likeliest one there is: 2.3
    /// GB has just landed, the disk is full, and `manifest.json` cannot be
    /// written. Everything before this row failed in the FETCH.
    ///
    /// The tree is then real, complete-looking and manifest-less, which
    /// `installState()` calls `.installedUnverified` — the pre-4v state
    /// AC-239 exists to end. The first version of the deletion guard asked
    /// `modelInstalled()`, which answers TRUE for that tree, so it was
    /// kept; and `download`'s own `guard !modelInstalled()` then returned
    /// early on every later attempt, so the manifest could never be
    /// written by anyone, ever. A fresh 4x install could reach a state
    /// only an old phone was supposed to have.
    ///
    /// The guard now protects a VERIFIED install and nothing else.
    @Test("a failure after the move leaves .absent, not a tree pretending to be installed")
    func aFailureAfterTheMoveLeavesNothingPretending() async throws {
        let base = try InstallScratch.directory("late")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalMindModel(repoID: "nobody/Fake-Model", in: base)
        let snapshot = base.appending(path: "snapshot")

        await #expect(throws: InstallFailure.self) {
            try await model.download(reporting: { _ in }, using: FakeWeightsFetcher { _, _, _ in
                try InstallScratch.tree(at: snapshot)
                // The manifest's slot is a DIRECTORY, so the write AFTER
                // the move fails the way a full disk makes it fail.
                try FileManager.default.createDirectory(
                    at: snapshot.appending(path: InstallManifest.fileName),
                    withIntermediateDirectories: true)
                return snapshot
            })
        }
        #expect(model.installState() == .absent,
                "a half-finished install this download made is removed, not left pretending")
        #expect(model.modelInstalled() == false,
                "so the next attempt is not short-circuited by download's own guard")
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
