import Foundation
import MultiModalKit

// THE SIZE, BEFORE ANYTHING IS FETCHED (4x, SPEC §181/1, AC-245, AC-246;
// Aura's L2, and D-106's F-5 = A).
//
// Aura wrapped `download(reporting:)` and stopped, because a 2.3 GB
// download a person pays for cannot be offered on a library whose only
// honest answer is "I will tell you the total once the bytes have
// arrived". The number IS knowable in advance: the Hub lists a repo's
// files with their sizes — in 4x through the client, a listing and a
// HEAD per file; since 5a in ONE request to the tree endpoint
// (`treeSizes`, `BackgroundWeightsFetcher.swift`), and the answer is
// kept beside the weights so the next time costs nothing (AC-294,
// D-114 F-5 = A).
//
// F-5 = A puts the question on `LocalMindModel`, beside `installState()`
// and `download` — one object owns the weights. Rejected: putting it on
// the fetcher protocol, which would make a caller need a fetcher in order
// to ask a question about a model.

// MARK: - what an install will cost (AC-245)

/// What installing a model will cost, before any of it is fetched.
///
/// Both totals are BYTES. They are equal today and the comment on
/// `onDiskBytes` says why — no multiplier is invented to make them look
/// different.
public struct InstallSize: Sendable, Equatable {
    /// One file the download would fetch, and its size on the server.
    public struct FileSize: Sendable, Equatable {
        /// The file's name in the repository.
        public let name: String
        /// Its size in bytes, as the repository reports it.
        public let bytes: Int64

        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// What will travel over the network: the sum of `files`.
    public let downloadBytes: Int64
    /// What will sit on disk afterwards.
    ///
    /// EQUAL TO `downloadBytes`, and that is a fact about this install
    /// path, not a rounding: the snapshot is MOVED into place exactly as
    /// it arrived (`completeInstall(movingFrom:)`), so nothing is
    /// unpacked, converted or re-quantised. The only thing added is
    /// `manifest.json`, a few hundred bytes of file names. The day an
    /// install repacks anything, this stops being a copy of the other
    /// number — and until then, a multiplier here would be a lie with a
    /// decimal point in it.
    public let onDiskBytes: Int64
    /// Every file, sorted by name, so a caller can show the breakdown and
    /// two runs read the same way.
    public let files: [FileSize]

    /// The only way to build one: the totals are derived, so they cannot
    /// disagree with the breakdown.
    public init(files: [FileSize]) {
        let sorted = files.sorted { $0.name < $1.name }
        let total = Self.saturatingSum(sorted.map(\.bytes))
        self.files = sorted
        self.downloadBytes = total
        self.onDiskBytes = total
    }

    /// The sum, SATURATING — the same rule, and the same scar, as
    /// `InstallManifest.totalBytes`: `reduce(0, +)` TRAPS on overflow,
    /// and these numbers come off a server this library does not own. A
    /// total larger than `Int64` can hold is "more than can be counted" —
    /// a number, not a termination — and it is only ever shown to a
    /// person as a size.
    static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { total, bytes in
            let (sum, overflowed) = total.addingReportingOverflow(bytes)
            guard !overflowed else { return bytes > 0 ? .max : .min }
            return sum
        }
    }
}

// MARK: - asking the repository (AC-245, AC-246)

extension LocalMindModel {

    /// The files a download asks the repository for. ONE constant,
    /// because AC-245's number must be about the same set of files the
    /// download actually fetches — a true total for the wrong set is
    /// still a lie to the person paying for the data. `HubWeightsFetcher`
    /// passes it to the snapshot; `expectedInstall()` passes it to the
    /// metadata call AND re-applies it to what comes back.
    static let weightGlobs = ["*.safetensors", "*.json", "*.txt"]

    /// True when a repository file name is one this download would fetch.
    /// `fnmatch` is the matcher the Hub client itself uses, so the two
    /// answers cannot drift apart.
    static func matchesWeightGlob(_ name: String) -> Bool {
        weightGlobs.contains { fnmatch($0, name, 0) == 0 }
    }

    /// WHERE THE SIZES COME FROM, AS A VALUE — the same shape 4v gave the
    /// fetch, and for the same reason: everything that matters is on the
    /// far side of a network call, so a test needs somewhere to stand.
    ///
    /// It is INTERNAL, not public. AC-249 makes the FETCH public because
    /// Aura must fake a download screen; nobody has asked to fake a size,
    /// and a second public protocol is a second promise to keep forever.
    typealias Sizing = @Sendable (
        _ repoID: String,
        _ globs: [String]
    ) async throws -> [InstallSize.FileSize]

    /// What installing this model will cost — **this makes ONE network
    /// call** (5a; AC-294).
    ///
    /// The name says so, and so does this sentence: a caller that puts it
    /// on a screen's `onAppear` makes one small request every time that
    /// screen appears. `expectedDownloadBytes()` is the free question —
    /// the last listing's total, kept beside the weights — and the one a
    /// screen asks on appear; this is the exact one, asked when a person
    /// is about to be shown "this needs 2.3 GB".
    ///
    /// It fetches NOTHING (AC-246): the request is the repository's tree,
    /// with every file's size in it. No weights are downloaded, no
    /// directory is created, and `installState()` is the same afterwards
    /// as before. What it does write is the listing, one small JSON
    /// BESIDE the weights directory — never in it.
    ///
    /// The number will drift the day the model is re-quantised — it is
    /// read from the repository on every call; only the free question
    /// reads the copy. 4x measured the client's way on 2026-09-10
    /// (INSTRUMENTS §66: nine files, 2 173 MB, asked in 3 388 ms — ten
    /// listings and nine HEADs); 5a measured the tree endpoint at 0.22 s
    /// for the same nine files (SPEC §199, Fact 4). `bakeoff
    /// install-size` is how to take the number again.
    ///
    /// - Throws: `ReplyFailure.unavailable(.weightsAbsent)` when this
    ///   model has no repository to ask — the same error the download
    ///   throws for the same reason, so a caller has one case, not two.
    ///   `InstallFailure.sizeUnknown(file:)` when a file's size cannot be
    ///   learned, because a total that quietly leaves the 2 GB file out
    ///   would be worse than no total at all.
    public func expectedInstall() async throws -> InstallSize {
        try await expectedInstall(asking: Self.treeSizes(host: Self.hubHost))
    }

    /// The question, with the metadata source handed in — the shape every
    /// test uses.
    ///
    /// THE GLOB IS PASSED AND RE-APPLIED. The seam is a value, and a
    /// value can be replaced by something that ignores what it was asked
    /// for; the filter here means such a source still cannot make this
    /// number a total about a different set of files. Real repositories
    /// make it matter too: a Qwen-shaped repo carries `.bin` copies of
    /// the same weights, which this download never fetches.
    ///
    /// AND THE ANSWER IS KEPT (5a, F-5 = A): the listing is written beside
    /// the weights, where `expectedDownloadBytes()` reads it with the
    /// network unplugged and a download's progress reads its total.
    func expectedInstall(asking sizes: Sizing) async throws -> InstallSize {
        guard let repoID else { throw ReplyFailure.unavailable(.weightsAbsent) }
        let listing = try await WeightsListing.list(repoID: repoID, asking: sizes)
        try listing.write(for: repoID, under: weights.deletingLastPathComponent())
        return InstallSize(files: listing.files.map { InstallSize.FileSize(name: $0.key, bytes: $0.value) })
    }
}
