import Foundation
import Hub
import MultiModalKit

// THE SIZE, BEFORE ANYTHING IS FETCHED (4x, SPEC §181/1, AC-245, AC-246;
// Aura's L2, and D-106's F-5 = A).
//
// Aura wrapped `download(reporting:)` and stopped, because a 2.3 GB
// download a person pays for cannot be offered on a library whose only
// honest answer is "I will tell you the total once the bytes have
// arrived". The number IS knowable in advance: the Hub lists a repo's
// file names, and one HEAD per file gives each file's size.
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

    /// What installing this model will cost — **this makes network
    /// calls.**
    ///
    /// The name says so, and so does this sentence, because a caller that
    /// puts it on a screen's `onAppear` will make a couple of small
    /// requests per file every time that screen appears. Ask it once,
    /// when a person is about to be shown "this needs 2.3 GB", and keep
    /// the answer.
    ///
    /// It fetches NOTHING (AC-246): the requests are a repository listing
    /// and a metadata HEAD per file (`hubSizes` has the exact count and
    /// why it is not one). No weights are downloaded, no directory is
    /// created, and `installState()` is the same afterwards as before.
    ///
    /// The number will drift the day the model is re-quantised — it is
    /// read from the repository every time, never cached in this library.
    /// Measured against the real repository on 2026-09-10 and written into
    /// INSTRUMENTS §66 with that date: nine files, 2 173 MB, asked in
    /// 3 388 ms, and zero bytes fetched by the asking. `bakeoff
    /// install-size` is how to take the number again.
    ///
    /// - Throws: `ReplyFailure.unavailable(.weightsAbsent)` when this
    ///   model has no repository to ask — the same error the download
    ///   throws for the same reason, so a caller has one case, not two.
    ///   `InstallFailure.sizeUnknown(file:)` when a file's size cannot be
    ///   learned, because a total that quietly leaves the 2 GB file out
    ///   would be worse than no total at all.
    public func expectedInstall() async throws -> InstallSize {
        try await expectedInstall(asking: Self.hubSizes)
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
    func expectedInstall(asking sizes: Sizing) async throws -> InstallSize {
        guard let repoID else { throw ReplyFailure.unavailable(.weightsAbsent) }
        let listed = try await sizes(repoID, Self.weightGlobs)
        return InstallSize(files: listed.filter { Self.matchesWeightGlob($0.name) })
    }

    /// The real one: the repository's listing, then one HEAD per file.
    ///
    /// TWO CALLS PER FILE, NOT ONE, and the reason is the client's shape
    /// rather than a choice. Its metadata value carries a `size` but no
    /// file NAME — the location it does carry is a CDN URL for anything
    /// stored as a large file — and the only public way to tie a size back
    /// to a name is to ask for one file at a time, by name. Pairing a
    /// bulk listing with a bulk metadata call by position would depend on
    /// two unordered sets landing in the same order, which is not a thing
    /// to bet a person's data allowance on.
    ///
    /// THE COUNT, CORRECTED. This comment said "nine listings and nine
    /// HEADs" for a nine-file model, and a review counted the calls in
    /// the client instead of trusting the sentence: the loop below makes
    /// ONE listing, and then `getFileMetadata(from:matching:)` makes its
    /// OWN listing before every HEAD. So nine files cost TEN listings and
    /// nine HEADs. All are small, and this is asked once — but the number
    /// a doc comment gives is a number somebody will plan around, so it
    /// says what the code does. (SPEC §180's "a nine-file model costs
    /// nine HEADs" reads on the HEADs alone and is still true of them; it
    /// is silent about the listings, which is a note for the spec, not a
    /// change to make here.)
    ///
    /// NONISOLATED BY CONSTRUCTION: this is a plain `@Sendable` closure,
    /// so the client's non-`Sendable` metadata values never cross an
    /// actor boundary — only the `FileSize` values it maps them into do.
    static let hubSizes: Sizing = { repoID, globs in
        // The client's download base is left at its default and never
        // touched: nothing here downloads, so nothing here writes a
        // directory. That is AC-246 in one line.
        let hub = HubApi()
        var sizes: [InstallSize.FileSize] = []
        for name in try await hub.getFilenames(from: repoID, matching: globs) {
            // The name IS the glob here, so exactly one file answers.
            let metadata = try await hub.getFileMetadata(from: repoID, matching: [name])
            guard let bytes = metadata.first?.size else {
                throw InstallFailure.sizeUnknown(file: name)
            }
            sizes.append(InstallSize.FileSize(name: name, bytes: Int64(bytes)))
        }
        return sizes
    }
}
