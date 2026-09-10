import Foundation
import Hub
import MultiModalKit

// THE INSTALL SEAM, MADE PUBLIC (4x, SPEC §181/3, AC-249) — and the
// typed failure a stopped install hands back (AC-248).
//
// In 4v the fetch became a value so this library's own tests could drive
// a real `download` without a network call. Aura needs the same thing
// from OUTSIDE the package: its download screen cannot be tested against
// a 2.3 GB download, and a screen nobody can test is a screen that ships
// wrong. So the value becomes a protocol with one method, the Hub's
// implementation becomes its default, and the acceptance test for this
// milestone is the one a caller copies.
//
// ONE METHOD, DELIBERATELY. A protocol is a promise to every conformer,
// and every extra requirement is a thing a caller's fake must get right
// before it can be used at all. This one asks for exactly what the
// download needs: put the files for this repo somewhere under this
// directory, say how far along you are, and hand back where you put them.

/// Where a model's weights come from.
///
/// The library ships `HubWeightsFetcher` and uses it by default; a caller
/// conforms its own when it wants a download screen it can test, or a
/// mirror of its own. Nothing else about the install changes: the guards,
/// the move into place, the manifest and the backup flag are this
/// library's, whoever brought the bytes.
///
/// `fetch` may be cancelled. A conformer that returns EARLY on
/// cancellation, as the Hub's client does, is handled — the install is
/// completed only after the cancellation is checked — but a conformer
/// that throws `CancellationError` is cleaner, and both leave the same
/// nothing behind (F-2 = A).
public protocol WeightsFetching: Sendable {
    /// Fetches `repoID`'s files under `base` and returns the directory
    /// they actually landed in.
    ///
    /// - Parameters:
    ///   - repoID: the model repository, `"owner/name"`.
    ///   - base: the directory to work under. A conformer may make
    ///     whatever tree it likes below this.
    ///   - progress: 0…1, called as often as it likes. Values outside
    ///     0…1 are clamped by the caller, so a conformer that reports a
    ///     rough number cannot break a progress bar.
    /// - Returns: the directory holding the fetched files. It is MOVED
    ///   into place afterwards, so it must not be somewhere the conformer
    ///   still needs.
    func fetch(repoID: String,
               into base: URL,
               reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// The real one, over the Hugging Face Hub client — the default for
/// `download(reporting:)`, and the only fetcher this library ships.
///
/// The first version of this searched the download base for any
/// `config.json` and moved the folder containing it. That was dangerous
/// rather than merely imprecise: an app's Documents directory holds other
/// models — this demo keeps Whisper's under
/// `huggingface/models/openai/…`, and those have a `config.json` too.
/// Directory enumeration has no defined order, so that code could have
/// moved somebody else's model. Never go looking for a file when the API
/// already told you the path.
public struct HubWeightsFetcher: WeightsFetching {
    public init() {}

    /// The hub returns WHERE it put the snapshot. Use that.
    public func fetch(repoID: String,
                      into base: URL,
                      reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let hub = HubApi(downloadBase: base)
        return try await hub.snapshot(
            from: repoID,
            matching: LocalMindModel.weightGlobs
        ) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
    }
}

// MARK: - what a stopped install says (AC-248)

/// Why an install did not finish — TYPED, so a caller can switch and
/// count, where before 4x a failed download arrived as whatever the
/// fetcher happened to throw.
///
/// The string cases follow D-103's F-3 = A, the ruling that gave
/// `ReplyFailure` its `.engine(String)`: the words are still there for a
/// screen, and the case is there for a switch. They carry
/// `String(describing:)` of the original error rather than its
/// `localizedDescription`, because an `Error` that is not a
/// `LocalizedError` renders as "The operation couldn't be completed",
/// which tells a person nothing at all.
///
/// CANCELLATION IS NOT HERE. A cancelled download throws
/// `CancellationError`, unwrapped, because cancellation is a thing the
/// CALLER asked for and not a failure of the install — the same
/// distinction §4.1's cancellation law draws.
public enum InstallFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The fetcher could not get the bytes.
    case fetchFailed(String)
    /// The bytes arrived, and putting them in place failed — a full
    /// disk, a directory that could not be made, a manifest that could
    /// not be written.
    case couldNotComplete(String)
    /// A file's size could not be learned, so `expectedInstall()` cannot
    /// give an honest total. Naming the file matters: the one whose size
    /// is missing is usually the 2 GB one.
    case sizeUnknown(file: String)

    public var description: String {
        switch self {
        case .fetchFailed(let words):
            "the download failed: \(words)"
        case .couldNotComplete(let words):
            "the download arrived but could not be put in place: \(words)"
        case .sizeUnknown(let file):
            "the download size is unknown — the repository did not give a size for \(file)"
        }
    }
}
