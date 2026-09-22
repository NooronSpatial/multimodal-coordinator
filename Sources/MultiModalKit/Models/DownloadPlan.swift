import Foundation

// THE PLAN (5a, SPEC §202, D-114 F-3 = A): what a download IS, before
// any byte moves — a list of files, each with where it comes from, where
// it lands and how big it should be. An engine builds one from its
// catalog (two static URLs for Kokoro; a repository listing for the
// mind and the ears); `ModelDownloader` moves it. Nothing in the
// downloader knows what a model is.

/// The files one `ensureModel` moves, and where they land.
///
/// Two plans with the same destinations are the SAME transfer: a second
/// `transfer` while one runs joins it (AC-296). The destination is the
/// final path — the file the engine's `modelInstalled()` reads — so a
/// complete file is skipped without a request, and a delete knows
/// exactly what to remove.
public struct DownloadPlan: Sendable, Equatable {
    /// One file of the plan.
    public struct File: Sendable, Equatable {
        /// Where the bytes come from — `https://…`.
        public let source: URL
        /// Where they land, as a file URL. Its directory is created; a
        /// file already there with `expectedBytes` bytes is complete and
        /// never asked for again.
        public let destination: URL
        /// How many bytes the file should be, when the catalog knows.
        /// `nil` means "whatever arrives": the file is complete when the
        /// transfer finishes, and a file already there is trusted.
        public let expectedBytes: Int64?

        public init(source: URL, destination: URL, expectedBytes: Int64?) {
            self.source = source
            self.destination = destination
            self.expectedBytes = expectedBytes
        }

        /// The name a failure carries.
        var name: String { destination.lastPathComponent }

        /// Where a stopped transfer keeps what it can resume (F-4 = A):
        /// beside the destination, as `<name>.resume`, until the file
        /// lands or a delete removes it.
        var resumeDataURL: URL { destination.appendingPathExtension("resume") }
    }

    public let files: [File]

    public init(files: [File]) {
        self.files = files
    }

    /// What makes two plans one transfer: the destinations.
    var key: String {
        files.map(\.destination.path).sorted().joined(separator: "\n")
    }
}

/// Why a transfer did not finish — TYPED, so a screen can switch and a
/// test can count (the same reasoning as `InstallFailure`, AC-248).
///
/// CANCELLATION IS NOT HERE: a cancelled transfer throws
/// `CancellationError`, unwrapped, because it is what the caller asked
/// for and not a failure of the download.
public enum DownloadFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The bytes could not be moved — the system's words, or the
    /// server's status. What could be resumed was kept (F-4 = A).
    case transferFailed(file: String, String)
    /// The file arrived, and it is not the size the catalog declared. It
    /// was removed: a short file is not left pretending.
    case shortFile(file: String, got: Int64, expected: Int64)
    /// The bytes arrived and could not be put in place — a full disk, a
    /// directory that could not be made.
    case couldNotPlace(file: String, String)
    /// The repository could not be listed, so no plan can be made
    /// (`HubTree`). The words are the request's.
    case listingFailed(repo: String, String)

    public var description: String {
        switch self {
        case .transferFailed(let file, let words):
            "the download of \(file) failed: \(words)"
        case .shortFile(let file, let got, let expected):
            "\(file) arrived as \(got) bytes, expected \(expected) — not kept"
        case .couldNotPlace(let file, let words):
            "\(file) arrived but could not be put in place: \(words)"
        case .listingFailed(let repo, let words):
            "\(repo) could not be listed: \(words)"
        }
    }
}
