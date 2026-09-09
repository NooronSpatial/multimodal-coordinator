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
    public static func at(fraction: Double, bytesExpected: Int64?) -> InstallProgress {
        let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        let received = bytesExpected.map { Int64((Double($0) * clamped).rounded(.down)) }
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

    var totalBytes: Int64 { files.values.reduce(0, +) }

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
    public nonisolated func readiness() -> MindUnavailable? {
        verdict(claimingMemory: true)
    }

    /// The LOAD's door: the same verdict WITHOUT the memory claim. The
    /// load is what the memory instruments measure (the demo's pressure
    /// probe, `bakeoff memory-fit`); refusing it on an estimate would
    /// block the very run that produces the real number. The reply door
    /// claims; the load door does not.
    nonisolated func loadVerdict() -> MindUnavailable? {
        verdict(claimingMemory: false)
    }

    private nonisolated func verdict(claimingMemory: Bool) -> MindUnavailable? {
        let report = DeviceReport.current(
            gpu: MLXRuntime.isAvailable ? .available : .absent,
            install: installState())
        let needs = MindNeeds(floor: report.platform.libraryFloor,
                              memoryBytes: claimingMemory ? estimatedWorkingSetBytes() : 0)
        return MindReadiness.verdict(for: report, needs: needs)
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
        guard !modelInstalled() else { return }
        guard let repoID else { throw ReplyFailure.unavailable(.weightsAbsent) }
        // AC-240: the expected total is a manifest's, when an earlier
        // install left one (a re-install after `.incomplete`); on a first
        // install there is no number, and none is invented.
        let expected = InstallManifest.read(in: weights)?.totalBytes
        let hub = HubApi(downloadBase: weights.deletingLastPathComponent())
        // The hub returns WHERE it put the snapshot. Use that.
        //
        // The first version of this searched the download base for any
        // `config.json` and moved the folder containing it. That was
        // dangerous rather than merely imprecise: an app's Documents
        // directory holds other models — this demo keeps Whisper's under
        // `huggingface/models/openai/…`, and those have a `config.json`
        // too. Directory enumeration has no defined order, so that code
        // could have moved somebody else's model. Never go looking for a
        // file when the API already told you the path.
        let snapshot = try await hub.snapshot(
            from: repoID,
            matching: ["*.safetensors", "*.json", "*.txt"]
        ) { downloadProgress in
            progress(InstallProgress.at(fraction: downloadProgress.fractionCompleted,
                                        bytesExpected: expected))
        }
        // THE HUB RETURNS EARLY ON CANCELLATION with a PARTIAL tree and no
        // error. A manifest written from that tree would list the short
        // files at their short sizes and call the install complete — the
        // exact lie AC-239 exists to end. So the cancel is checked here,
        // before anything is moved or written.
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
