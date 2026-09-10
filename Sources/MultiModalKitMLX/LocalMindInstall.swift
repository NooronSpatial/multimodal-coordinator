import Foundation
import MultiModalKit
import Synchronization

// THE INSTALL, SIZE-CHECKED (4v, SPEC §175/6–7, AC-239, AC-240) — and the
// door's verdict (§175/5, AC-238's wiring).
//
// Before 4v "installed" meant "a file with the right name exists"
// (D-101's L1). A download that died at 1 GB of 2.3 left a tree that
// passed every check and failed on the first token. So a COMPLETE
// download now writes `manifest.json` — every file, every byte — and
// the state is verified against it. The Hub client cannot supply the
// numbers: its progress counts FILES (one unit each, `HubApi.snapshot`),
// so the bytes are read from the disk the moment the snapshot returns.

// MARK: - progress with bytes (AC-240)

/// How far an install has come, with bytes when they are KNOWN and `nil`
/// when they are not. The Hub path knows a fraction of files; a manifest
/// left by an earlier install knows the total; the two together give a
/// received count.
///
/// AND THAT COUNT IS DERIVED, NOT COUNTED — written here plainly because
/// the 4v review was right that "nothing is invented to fill a field"
/// read as a promise this one field does not keep. The Hub's client
/// counts FILES, one unit each (`HubApi.snapshot`), so `bytesReceived` is
/// a FILE fraction multiplied by a byte total: with one 2 GB weight file
/// beside four small JSONs, "80% of files" is a few megabytes, not 80% of
/// the bytes. It is an honest progress BAR and a poor byte counter, and
/// a caller must not read it as a measurement.
///
/// What is never invented is the EXPECTED total: it stays `nil` until a
/// manifest has actually seen those bytes arrive (§175/7, AC-240).
/// Whether a derived received-count should be published at all is a
/// question for Ryad — AC-240 asks the Hub path for "its client's
/// fraction plus the manifest's expected bytes", and this field is more
/// than that. Reported, not decided here.
public struct InstallProgress: Sendable, Equatable {
    /// 0…1, from the client.
    public var fraction: Double
    /// `fraction × bytesExpected` — DERIVED from the client's fraction,
    /// never counted (see above) — or `nil` when the total is unknown.
    public var bytesReceived: Int64?
    /// The manifest's total, or `nil` on a first install.
    public var bytesExpected: Int64?

    public init(fraction: Double, bytesReceived: Int64?, bytesExpected: Int64?) {
        self.fraction = fraction
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
    }

    /// The arithmetic, pure: clamps the client's fraction to 0…1 (it has
    /// been seen outside), and derives `received` only when `expected`
    /// is a number.
    ///
    /// NaN IS CLAMPED BY HAND, and it must be. `min(max(x, 0), 1)` does
    /// NOT clamp NaN — every comparison against NaN is false, so both
    /// calls hand the NaN straight back — and the line below then asks
    /// `Int64` for it, which TRAPS. The 4v review ran that against this
    /// public function and killed the test process ("Double value cannot
    /// be converted to Int64 because it is either infinite or NaN").
    /// ±infinity was always clamped correctly; only NaN escaped, which is
    /// exactly the case this comment claimed was handled. A NaN fraction
    /// is "no progress reported", so it reads as 0 — never a termination
    /// a caller's client can reach (the rule AC-241 exists for).
    ///
    /// AND THE TOTAL IS AN INPUT TOO — the second review found the same
    /// line trapping from the other side. `Double(Int64.max)` rounds UP to
    /// exactly 2^63, so `Double(total) * 1.0` is one step past what `Int64`
    /// can hold and the conversion died: "Double value cannot be converted
    /// to Int64 because the result would be greater than Int64.max",
    /// signal 5. That total is read from a `manifest.json` on disk
    /// (`expectedBytes()`), and the weights directory defaults to the app's
    /// Documents — a place `LocalMind` itself says a person "can also drop
    /// the folder by hand over USB" — so it is not a number this library
    /// controls. `Int64(exactly:)` ASKS instead of assuming, and received
    /// is capped at expected, which is the only honest answer anyway.
    public static func at(fraction: Double, bytesExpected: Int64?) -> InstallProgress {
        let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        let received = bytesExpected.map { total -> Int64 in
            let scaled = (Double(total) * clamped).rounded(.down)
            guard let exact = Int64(exactly: scaled) else { return total }
            return min(exact, total)
        }
        return InstallProgress(fraction: clamped, bytesReceived: received, bytesExpected: bytesExpected)
    }
}

// MARK: - the manifest (AC-239)

/// `manifest.json`, beside the weights: `{"files": {"<name>": <bytes>}}`.
/// Written ONLY by a complete download; read by `installState()`.
struct InstallManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"

    /// File name → byte count, for every regular file the download put
    /// in the directory.
    var files: [String: Int64]

    init(files: [String: Int64]) { self.files = files }

    /// The directory as it is NOW — the source of the numbers, because
    /// the Hub client counts files, not bytes.
    init(listing directory: URL) throws {
        self.files = try Self.listing(of: directory)
    }

    /// Every regular, non-hidden file with its size. The manifest never
    /// lists itself, and the Hub's own `.cache` bookkeeping is hidden.
    ///
    /// LINKS ARE FOLLOWED. The Hub cache on a Mac (`~/.cache/huggingface`)
    /// is a snapshot of SYMLINKS into a blob store, and
    /// `attributesOfItem` reports the link, not the file — the first
    /// version of this saw `.typeSymbolicLink` for every weight and
    /// called a working install `.absent` (the live suite caught it in
    /// its first run). A dangling link is not a file and is skipped.
    static func listing(of directory: URL) throws -> [String: Int64] {
        let files = FileManager.default
        var sizes: [String: Int64] = [:]
        for name in try files.contentsOfDirectory(atPath: directory.path)
        where !name.hasPrefix(".") && name != fileName {
            let resolved = directory.appending(path: name).resolvingSymlinksInPath()
            guard let attributes = try? files.attributesOfItem(atPath: resolved.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            sizes[name] = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return sizes
    }

    /// The sum, SATURATING. `reduce(0, +)` traps on overflow, and these
    /// numbers are decoded off disk, not counted here: the second 4v
    /// review wrote two `Int64.max` entries into a `manifest.json`, read
    /// it back (the decode printed both numbers) and the process died on
    /// the sum, "exited with unexpected signal code 5". A total larger
    /// than `Int64` can hold is "more than can be counted" — a number, not
    /// a termination (AC-241's rule) — and it is only ever shown to a
    /// person as a progress bar's total.
    var totalBytes: Int64 {
        files.values.reduce(Int64(0)) { total, bytes in
            let (sum, overflowed) = total.addingReportingOverflow(bytes)
            guard !overflowed else { return bytes > 0 ? .max : .min }
            return sum
        }
    }

    /// The names that are missing or SHORTER than listed, sorted so a
    /// verdict reads the same way twice. Longer is not reported: a file
    /// that grew is not a download that died.
    func shortfall(against onDisk: [String: Int64]) -> [String] {
        files.filter { name, bytes in (onDisk[name] ?? -1) < bytes }.keys.sorted()
    }

    func write(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }

    /// `nil` when there is no manifest, or one this version cannot read
    /// — either way the tree is judged by its files alone.
    static func read(in directory: URL) -> InstallManifest? {
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(InstallManifest.self, from: data)
    }
}

// MARK: - the model's install questions

extension LocalMindModel {

    /// The files "installed" has always required — OFFLINE-CAPABLE, the
    /// lesson Whisper's audit wrote down: weights without a tokenizer
    /// are a silent network fetch waiting to happen.
    private static func requiredFilesPresent(in onDisk: [String: Int64]) -> Bool {
        onDisk["config.json"] != nil
            && onDisk["tokenizer.json"] != nil
            && onDisk["tokenizer_config.json"] != nil
            && onDisk.keys.contains { $0.hasSuffix(".safetensors") }
    }

    /// The rule, pure, over a manifest and a listing (AC-239):
    /// - a manifest, and any file missing or short → `.incomplete(files:)`;
    /// - a manifest with no shortfall, over an OFFLINE-CAPABLE tree
    ///   → `.installed`;
    /// - no manifest, but the required files → `.installedUnverified` —
    ///   a pre-4v install, the phones in the field; they ran yesterday,
    ///   and a missing manifest is not evidence of a missing file;
    /// - otherwise → `.absent`.
    ///
    /// A MANIFEST IS NOT A LICENCE, and the 4v review caught this branch
    /// treating it as one: it answered `shortfall.isEmpty ? .installed`
    /// and never asked the offline-capable question, so a tree holding
    /// nothing but `config.json` — with a manifest written from that tree,
    /// which of course has no shortfall — was `.installed`,
    /// `modelInstalled()` was true, the verdict was nil, and
    /// `download`'s `guard !modelInstalled()` returned early forever. It
    /// is reachable: the snapshot asks for `*.safetensors, *.json, *.txt`,
    /// so a repo with `.bin`/`.gguf` weights or a sentencepiece-only
    /// tokenizer lands exactly that tree.
    ///
    /// The shortfall is asked FIRST because it is the more informative
    /// answer — it NAMES the files — and only a complete manifest reaches
    /// the capability question. The word for a tree that cannot answer
    /// offline is `.absent`, the same word the no-manifest path already
    /// gives for the same tree: one tree, one verdict, manifest or not.
    static func installState(manifest: InstallManifest?, onDisk: [String: Int64]) -> InstallState {
        if let manifest {
            let short = manifest.shortfall(against: onDisk)
            guard short.isEmpty else { return .incomplete(files: short) }
            return requiredFilesPresent(in: onDisk) ? .installed : .absent
        }
        return requiredFilesPresent(in: onDisk) ? .installedUnverified : .absent
    }

    /// What is on disk, verified (AC-239). Nonisolated and cheap: a
    /// directory listing and one small JSON — never a load, never a
    /// network call, so the door can ask it on every turn.
    public nonisolated func installState() -> InstallState {
        let onDisk = (try? InstallManifest.listing(of: weights)) ?? [:]
        return Self.installState(manifest: InstallManifest.read(in: weights), onDisk: onDisk)
    }

    /// The working set loading these weights is expected to need, in
    /// bytes: the safetensors on disk × 1.5. An ESTIMATE from the
    /// measured phone peaks (INSTRUMENTS §58/§60: ~3.3 GB peak for 2.3 GB
    /// of weights), stated as integer arithmetic so it is exact. `0` when
    /// the weights are absent — no claim on a number we do not have —
    /// and `0` once they are RESIDENT: the headroom the report measures
    /// has already paid for them, and a model that is loaded and
    /// answering must not be refused for the memory it already holds.
    ///
    /// A QUESTION A CALLER MAY ASK, AND NOT A GATE. The first 4v version
    /// fed this number into the reply door's `MindNeeds` and left the
    /// load door without it, an asymmetry no AC asked for and no fork
    /// ruled — and the second review showed where it leads: the estimate
    /// drops to 0 only once the weights are resident, residency happens
    /// inside `ensureModelLoaded()`, and a refused reply door never gets
    /// there, so a phone whose headroom is below weights × 1.5 was locked
    /// out for good unless the caller happened to call the OPTIONAL
    /// `prewarm()`. 2.3 GB × 1.5 is 3.45 GB and iOS kills this app near
    /// 3351 MB (INSTRUMENTS §27), so that phone is the phone this library
    /// is for. Worse, no test on a Mac could see it: headroom is
    /// `.unavailable(.noMemoryLimitOnThisPlatform)` here, so the verdict's
    /// memory branch never ran. The ×1.5 is a policy number, not a
    /// measurement (§58/§60 measured a PEAK, not a gate), and whether a
    /// reply door should claim one at all is a fork for Ryad — reported,
    /// not ruled here. Until it is ruled the doors ask what AC-238 asks.
    public nonisolated func estimatedWorkingSetBytes() -> Int {
        guard !resident.withLock({ $0 }) else { return 0 }
        let onDisk = (try? InstallManifest.listing(of: weights)) ?? [:]
        let weightBytes = onDisk.filter { $0.key.hasSuffix(".safetensors") }.values.reduce(0, +)
        let bytes = Int(weightBytes)
        return bytes + bytes / 2
    }

    // MARK: the verdict (AC-238's wiring)

    /// Why this device cannot run this mind right now, or `nil`. The
    /// report is THIS machine's, filled by the one live reader
    /// (`DeviceReport.current`); the ruling is the pure function every
    /// hand-written row in `MindReadinessTests` already proves.
    ///
    /// The GPU answer is `MLXRuntime.isAvailable`, which is `false` on
    /// the Simulator AND on a Mac with no `default.metallib`. The two
    /// stay distinct because the report carries `isSimulator` separately
    /// and the verdict checks it FIRST: the Simulator is told it is the
    /// Simulator; a Mac without the shader library is told `.noGPU`.
    /// (For that Mac the fix is `Scripts/metallib.sh` — a developer's
    /// note, which is why it is here and not in the sentence a person
    /// reads.)
    ///
    /// ONE DOOR, ONE QUESTION — the reply door and the load door ask the
    /// same thing. The first 4v version had the reply door claim
    /// `estimatedWorkingSetBytes()` while the load door claimed nothing;
    /// the review found that asymmetry decided by the code, asserted by no
    /// test, and able to close the reply door permanently on a phone (the
    /// note on `estimatedWorkingSetBytes()` has the arithmetic). What the
    /// mind asks of a device is now `needs(for:)` — a pure function of the
    /// report that a test writes by hand.
    public nonisolated func readiness() -> MindUnavailable? {
        let report = DeviceReport.current(
            gpu: MLXRuntime.isAvailable ? .available : .absent,
            install: installState())
        return MindReadiness.verdict(for: report, needs: Self.needs(for: report))
    }

    /// What this mind requires of the device the report describes: the
    /// LIBRARY's floor for that platform (iOS 18 / macOS 15, D-091), and
    /// no memory claim. AC-238 puts `.notEnoughMemory` in the enum and
    /// proves it over hand-written reports in `MindReadinessTests`;
    /// nothing in §175/5 or AC-238 asks THIS door to compute an estimate,
    /// and a mind that makes no claim is never refused for memory.
    static func needs(for report: DeviceReport) -> MindNeeds {
        MindNeeds(floor: report.platform.libraryFloor, memoryBytes: 0)
    }

    // MARK: the download (AC-239, AC-240)

    /// Downloads the weights, if this model knows where they come from,
    /// reporting bytes when they are known.
    ///
    /// EXPLICIT, exactly as Whisper's rule requires: nothing here is ever
    /// reached by *asking* whether the model is installed. Idempotent —
    /// the download half is skipped when the tree is complete, and a
    /// pre-4v tree WITHOUT a manifest is left without one: only a
    /// download writes the manifest, because only a download has seen
    /// the bytes arrive. Such a tree stays `.installedUnverified` until
    /// it is fetched again.
    ///
    /// **THE SUSPEND TRUTH (AC-251, D-106's F-3 = A).** This download
    /// dies when the app leaves the foreground. It runs on an ordinary
    /// foreground `URLSession` — the client's background-session switch
    /// is left off, at its default — so the moment a person locks the
    /// phone or switches app, the system suspends this process and the
    /// transfer stops. There is no background session and no resume.
    ///
    /// What a caller must do about it: keep the screen alive while the
    /// weights come down — an idle timer disabled, and a person told why
    /// — or start the download again. Starting again is always safe, and
    /// with the fetcher this library ships it begins at zero:
    /// the partial tree is deleted, and the client's resume bookkeeping
    /// lives inside that tree and goes with it (`HubWeightsFetcher`). A
    /// caller that brings its OWN fetcher decides that for itself; the
    /// protocol asks it to clear what it wrote.
    ///
    /// That is D-106's F-3 = A, ruled and not merely settled for: a
    /// background `URLSession` is what a 2.3 GB cellular download really
    /// needs, and it is a different downloader, a delegate and a re-entry
    /// path — a milestone of its own, not a bullet in this one.
    /// `MLXInstallSuspendTests` reads this module's source and fails if a
    /// background session ever appears underneath this paragraph.
    ///
    /// - Throws: `ReplyFailure.unavailable(.weightsAbsent)` when this
    ///   model has no repository to fetch from; `CancellationError` when
    ///   the caller cancels; `InstallFailure` otherwise (AC-248).
    public func download(
        reporting progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        try await download(reporting: progress, using: HubWeightsFetcher())
    }

    /// The download, with the fetcher handed in — Aura's seam (AC-249),
    /// and the shape every test uses.
    ///
    /// The fetch became a value in 4v because the second review was right
    /// that AC-239's central promise — a COMPLETE download writes
    /// `manifest.json` — was asserted by no test at all, and could not be:
    /// everything that matters here is on the far side of a network call.
    /// The only row that called `download` proved the EARLY RETURN and
    /// pinned that no manifest was written. So the fetch became an
    /// argument with the Hub's as its default, and the guard, the move,
    /// the wiring and the write are proven by `MLXDownloadTests` with a
    /// fake fetch that writes a small tree.
    ///
    /// 4x made that value a public protocol (`WeightsFetching`), because
    /// Aura's download screen needs the same standing ground from outside
    /// the package.
    ///
    /// WHAT A STOPPED DOWNLOAD LEAVES BEHIND is the other half (AC-247,
    /// AC-248, F-2 = A): nothing that pretends. On a cancel or a throw the
    /// partial tree goes, so `installState()` answers `.absent` — or, when
    /// a caller's own earlier tree was already there, the `.incomplete`
    /// it already was. The cost is that a person who cancels at 90% pays
    /// again; B, keep-and-resume, was rejected because "resume" is a
    /// promise that must be tested on a bad network and this Mac cannot
    /// do that honestly.
    ///
    /// THE DELETING IS SPLIT IN TWO, and a review had to find out why.
    /// This function can only remove what it can NAME: the weights tree,
    /// and the directory a fetch RETURNED. A fetch that THROWS returns no
    /// path at all — and going looking for one is the mistake
    /// `HubWeightsFetcher`'s own note records, where code moved a folder
    /// because it found a `config.json` in it. So the throw path is the
    /// conformer's own to clean, `WeightsFetching` says so as a
    /// requirement, and the fetcher this library ships keeps it.
    public func download(
        reporting progress: @escaping @Sendable (InstallProgress) -> Void,
        using fetcher: some WeightsFetching
    ) async throws {
        guard !modelInstalled() else { return }
        guard let repoID else { throw ReplyFailure.unavailable(.weightsAbsent) }
        // AC-240: the expected total is a manifest's, when an earlier
        // install left one (a re-install after `.incomplete`); on a first
        // install there is no number, and none is invented.
        let expected = expectedBytes()
        // WHOSE TREE IS IT — read BEFORE the fetch, because after it the
        // answer is about a directory this download may have made. It is
        // the whole of the deletion guard: a tree that was already there
        // belongs to the caller and is never removed by a failure here.
        let treeWasAlreadyThere = FileManager.default.fileExists(atPath: weights.path)

        let snapshot: URL
        do {
            snapshot = try await fetcher.fetch(
                repoID: repoID,
                into: weights.deletingLastPathComponent()
            ) { fraction in
                progress(InstallProgress.at(fraction: fraction, bytesExpected: expected))
            }
        } catch {
            // No snapshot path to name: a fetcher that threw never said
            // where it was working, and guessing at a directory to delete
            // is exactly the mistake `HubWeightsFetcher`'s note records —
            // that code once moved a folder because it found a
            // `config.json` in it. So F-2 = A's other half is the
            // FETCHER's: `WeightsFetching` requires a conformer that
            // throws to remove what it wrote, and the shipped one does.
            // Everything this side can still name — a weights tree this
            // download created — is removed below.
            discardPartialInstall(snapshot: nil, keeping: treeWasAlreadyThere)
            throw error is CancellationError ? error : InstallFailure.fetchFailed(words(for: error))
        }
        do {
            try completeInstall(movingFrom: snapshot)
        } catch {
            discardPartialInstall(snapshot: snapshot, keeping: treeWasAlreadyThere)
            throw error is CancellationError ? error
                : InstallFailure.couldNotComplete(words(for: error))
        }
    }

    /// The error's own words. `String(describing:)` and not
    /// `localizedDescription`, because an `Error` that is not a
    /// `LocalizedError` renders as "The operation couldn't be completed",
    /// which tells a person nothing — the same reasoning D-103's F-3 = A
    /// used for `ReplyFailure.engine(String)`.
    private nonisolated func words(for error: any Error) -> String {
        String(describing: error)
    }

    /// F-2 = A, and the one destructive line in this file.
    ///
    /// DELETING A TREE CAN LOSE SOMEBODY'S 2.3 GB, so the rule is as
    /// narrow as it can be written: this removes the scratch the FETCH
    /// handed back — and only when that scratch is somewhere this
    /// download could have made it — and the weights tree only when THIS
    /// download created it and did not finish it. A tree that existed
    /// before the download started is the caller's — from an earlier
    /// attempt, or dropped in by hand over USB, which `LocalMindModel`
    /// explicitly invites — and a failure here is no reason to take it
    /// away. `MLXInstallSeamTests` proves every direction.
    ///
    /// Failures are swallowed: this runs while another error is already
    /// on its way to the caller, and a `removeItem` that could not is not
    /// the news. What it leaves is still honest, because `installState()`
    /// judges the tree by its files either way.
    private nonisolated func discardPartialInstall(snapshot: URL?, keeping wasAlreadyThere: Bool) {
        let files = FileManager.default
        if let snapshot, mayDelete(snapshot) {
            try? files.removeItem(at: snapshot)
        }
        guard !wasAlreadyThere else { return }
        // THE REENTRANCY LAW, and it is load-bearing here. `wasAlreadyThere`
        // was read BEFORE the fetch, and an actor interleaves at every
        // await: two downloads on the same model both pass the `guard
        // !modelInstalled()`, both see an empty directory, and if the
        // slower one then fails it would delete the tree the faster one
        // had just finished writing. So the disk is asked again NOW — a
        // COMPLETE install is never deleted, whoever finished it. There
        // is no gap to exploit, because `completeInstall` is synchronous:
        // the move and the manifest happen inside one actor step.
        //
        // AND "COMPLETE" MEANS VERIFIED, which this line first got wrong.
        // It asked `modelInstalled()`, which is TRUE for a manifest-less
        // tree as well — and a failure AFTER the move makes exactly that
        // tree: 2.3 GB has landed, the disk is full, `manifest.json`
        // cannot be written. The half-finished tree was then kept,
        // `installState()` called it `.installedUnverified`, and
        // `download`'s own `guard !modelInstalled()` returned early on
        // every later attempt — so no download could ever write the
        // manifest again. A fresh 4x install could reach the pre-4v state
        // AC-239 exists to end. Only `.installed` is protected now.
        guard installState() != .installed else { return }
        try? files.removeItem(at: weights)
    }

    /// Whether a directory a fetcher handed back is one THIS download
    /// could have created — the bound on the line above.
    ///
    /// `WeightsFetching` is public since AC-249, and its promise reads
    /// "put the files under `base` and hand back where you put them". A
    /// conformer that writes straight into `base` and returns `base` is
    /// reading that plainly. The default `base` is the app's Documents,
    /// so the unbounded version of this deleted a person's Documents —
    /// with another model's weights inside it — the moment the move into
    /// place failed. A review probe did it in four lines.
    ///
    /// The bound: strictly BELOW the base this download handed to the
    /// fetcher, and never an ancestor of (nor equal to) the weights tree.
    /// Symlinks are resolved on both sides first, because the temporary
    /// directories these run in are reached through them and two spellings
    /// of one path must not read as two paths. Anything failing the test
    /// is simply left alone: the same choice the `wasAlreadyThere` guard
    /// makes, for the same reason.
    private nonisolated func mayDelete(_ snapshot: URL) -> Bool {
        let parts = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        let base = parts(weights.deletingLastPathComponent())
        let candidate = parts(snapshot)
        guard candidate.count > base.count, Array(candidate.prefix(base.count)) == base else { return false }
        return !parts(weights).starts(with: candidate)
    }

    /// The manifest's total from an earlier install, or `nil` on a first
    /// one (AC-240). Its own function so the Hub path's one source of a
    /// byte number can be read by a test.
    nonisolated func expectedBytes() -> Int64? {
        InstallManifest.read(in: weights)?.totalBytes
    }

    /// Everything after the bytes land: the cancel, the move, the write.
    ///
    /// THE HUB RETURNS EARLY ON CANCELLATION with a PARTIAL tree and no
    /// error. A manifest written from that tree would list the short
    /// files at their short sizes and call the install complete — the
    /// exact lie AC-239 exists to end. So the cancel is checked here,
    /// before anything is moved or written.
    nonisolated func completeInstall(movingFrom snapshot: URL) throws {
        try Task.checkCancellation()

        if snapshot != weights {
            let files = FileManager.default
            if files.fileExists(atPath: weights.path) {
                try files.removeItem(at: weights)
            }
            try files.createDirectory(at: weights.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try files.moveItem(at: snapshot, to: weights)
        }
        // AC-239: the manifest, from the bytes ON DISK right after the
        // snapshot returned — the client counts files, not bytes.
        try InstallManifest(listing: weights).write(in: weights)
        excludeWeightsFromBackup()
    }

    /// AC-250 (Aura's L7): the weights are a re-downloadable cache, and a
    /// 2.3 GB cache inside a person's iCloud backup is a bill they never
    /// agreed to.
    ///
    /// AFTER EVERY DOWNLOAD, NOT ONLY AT CREATION — which is the whole
    /// point of the acceptance criterion. `completeInstall` MOVES a fresh
    /// snapshot into place, and the directory that arrives is a different
    /// directory from the one that was flagged: a mark set once, when the
    /// weights first appeared, would silently be gone after the repair
    /// that replaced them. So it is set here, on the last line of every
    /// install, and the test clears it by hand and downloads again.
    ///
    /// The failure is swallowed on purpose. A filesystem that will not
    /// take the flag is not a reason to throw away a complete, working
    /// install — and if the flag ever stops being applied where it
    /// matters, `MLXInstallSeamTests` fails, loudly, on this Mac.
    nonisolated func excludeWeightsFromBackup() {
        var directory = weights
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    /// The pre-4v shape, kept as a thin convenience over the byte-aware
    /// one so the demo and the `fetch` instrument keep compiling; the
    /// demo moves to `InstallProgress` by hand, later.
    public func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try await download(reporting: { progress($0.fraction) })
    }
}
