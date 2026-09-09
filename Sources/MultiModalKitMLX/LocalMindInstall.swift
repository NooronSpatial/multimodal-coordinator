import Foundation
import Hub
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
    public func download(
        reporting progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        try await download(reporting: progress, fetching: Self.hubFetch)
    }

    /// WHERE THE BYTES COME FROM, AS A VALUE: a repo id and a download
    /// base in, the directory the fetch actually filled out, fractions
    /// reported along the way.
    ///
    /// This exists because the second 4v review was right that AC-239's
    /// central promise — a COMPLETE download writes `manifest.json` — was
    /// asserted by no test at all, and could not be: everything that
    /// matters here is on the far side of a network call. The only row
    /// that called `download` proved the EARLY RETURN and pinned that no
    /// manifest was written. So the fetch became an argument with the
    /// Hub's as its default (`hubFetch`), and the guard, the move, the
    /// wiring and the write are now proven by `MLXDownloadTests` with a
    /// fake fetch that writes a small tree. Nothing public changed.
    typealias Fetching = @Sendable (
        _ repoID: String,
        _ into: URL,
        _ reporting: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    /// The real one. The hub returns WHERE it put the snapshot. Use that.
    ///
    /// The first version of this searched the download base for any
    /// `config.json` and moved the folder containing it. That was
    /// dangerous rather than merely imprecise: an app's Documents
    /// directory holds other models — this demo keeps Whisper's under
    /// `huggingface/models/openai/…`, and those have a `config.json`
    /// too. Directory enumeration has no defined order, so that code
    /// could have moved somebody else's model. Never go looking for a
    /// file when the API already told you the path.
    static let hubFetch: Fetching = { repoID, into, report in
        let hub = HubApi(downloadBase: into)
        return try await hub.snapshot(
            from: repoID,
            matching: ["*.safetensors", "*.json", "*.txt"]
        ) { downloadProgress in
            report(downloadProgress.fractionCompleted)
        }
    }

    /// The download, with the fetch handed in — the shape every test uses.
    func download(
        reporting progress: @escaping @Sendable (InstallProgress) -> Void,
        fetching fetch: Fetching
    ) async throws {
        guard !modelInstalled() else { return }
        guard let repoID else { throw ReplyFailure.unavailable(.weightsAbsent) }
        // AC-240: the expected total is a manifest's, when an earlier
        // install left one (a re-install after `.incomplete`); on a first
        // install there is no number, and none is invented.
        let expected = expectedBytes()
        let snapshot = try await fetch(repoID, weights.deletingLastPathComponent()) { fraction in
            progress(InstallProgress.at(fraction: fraction, bytesExpected: expected))
        }
        try completeInstall(movingFrom: snapshot)
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
