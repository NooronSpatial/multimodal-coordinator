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
// ONE METHOD, DELIBERATELY — and since 5a a second with a default, for
// the delete. A protocol is a promise to every conformer, and every
// extra requirement is a thing a caller's fake must get right before it
// can be used at all. The first asks for exactly what the download
// needs: put the files for this repo somewhere under this directory,
// say how far along you are, and hand back where you put them. The
// second asks what `deleteModel()` needs and nothing else: remove what
// you keep between attempts; a conformer that keeps nothing leaves the
// default in place.
//
// SINCE 5a THE DEFAULT IS `BackgroundWeightsFetcher` (D-114 F-3 = A):
// one request lists the repository, `ModelDownloader` moves the bytes
// on a background session, and a stopped transfer keeps what it can
// resume (F-4 = A). `HubWeightsFetcher` — the Hub client's own transfer
// — stays public for the callers who had it, and is foreground-only.

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
/// that throws `CancellationError` is cleaner.
///
/// WHO KEEPS WHAT, since 5a (D-114 F-4 = A, reversing D-106 F-2 = A). A
/// stopped transfer KEEPS what it can resume: the library never deletes
/// a directory a fetch was working in because the fetch was cancelled
/// or failed — on a cancel it does not even delete one the fetch handed
/// back — so the next attempt resumes instead of paying again. What a
/// conformer keeps is its own, below `base` and never inside the weights
/// directory (`installState()` reads that and nothing else, so it cannot
/// lie about a partial); `discard(repoID:under:)` is where it lets go,
/// and `deleteModel()` calls it. A conformer whose transfer cannot
/// resume — `HubWeightsFetcher`, whose resume would be the vendor
/// client's and is measured nowhere in this house — removes its
/// leftovers on the throw instead, so that "kept" never means "kept for
/// nothing".
public protocol WeightsFetching: Sendable {
    /// Fetches `repoID`'s files under `base` and returns the directory
    /// they actually landed in.
    ///
    /// **A CONFORMER THAT THROWS KEEPS WHAT IT CAN RESUME** (F-4 = A),
    /// below `base` and outside the weights directory, and removes it in
    /// `discard(repoID:under:)`. One that cannot resume removes its
    /// leftovers before the error leaves this method. Either way the
    /// throw carries no path, and nothing outside this method goes
    /// looking for one — the first `HubWeightsFetcher` did, and could
    /// have moved somebody else's model.
    ///
    /// - Parameters:
    ///   - repoID: the model repository, `"owner/name"`.
    ///   - base: the directory to work under. A conformer may make
    ///     whatever tree it likes below this — but `base` itself is not
    ///     its own to hand back: the returned directory is MOVED into
    ///     place, and a directory cannot be moved inside itself. The
    ///     install refuses to delete anything that is not strictly below
    ///     `base`, so a conformer that returns `base` fails the install
    ///     and loses nothing.
    ///   - progress: 0…1, called as often as it likes. Values outside
    ///     0…1 are clamped by the caller, so a conformer that reports a
    ///     rough number cannot break a progress bar.
    /// - Returns: the directory holding the fetched files. It is MOVED
    ///   into place afterwards, so it must not be somewhere the conformer
    ///   still needs. Make it a directory of the conformer's OWN, not the
    ///   weights directory itself: everything the install promises about a
    ///   failure — that a caller's existing tree survives it untouched —
    ///   rests on the new bytes being completed somewhere else first, and
    ///   a conformer that writes over the live tree has spent that
    ///   protection before this library is asked anything.
    func fetch(repoID: String,
               into base: URL,
               reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    /// Removes whatever this conformer keeps for `repoID` under `base`
    /// between attempts — a partial tree, resume data — and stops a
    /// transfer of it in flight. `deleteModel()` calls this (5a,
    /// AC-295); the default does nothing, for a conformer that keeps
    /// nothing. Never throws: it runs beside the weights' own removal,
    /// and what it could not remove is reported by the disk, not by an
    /// error a delete could not act on.
    func discard(repoID: String, under base: URL) async
}

public extension WeightsFetching {
    /// A conformer that keeps nothing between attempts has nothing to
    /// let go of.
    func discard(repoID: String, under base: URL) async {}
}

/// The Hub client's own transfer — the default for `download(reporting:)`
/// from 4v to 4z, kept public since 5a for callers who had it.
///
/// FOREGROUND ONLY, and said plainly (D-114 F-3 = A): this transfer runs
/// on the client's ordinary session and dies when the app leaves the
/// foreground; the client's background switch is left off because
/// turning it on crashes the process on this OS
/// (`docs/evidence/5a/probes/probe1.out.txt`). A download that must
/// survive the background goes through `BackgroundWeightsFetcher`, the
/// default now. This one keeps D-106's rule on a throw — its partial is
/// removed — because its resume would be the vendor client's, which
/// nothing in this house has measured (F-4 = A keeps what CAN be
/// resumed, and this library cannot say that this can).
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
    ///
    /// AND ON A THROW IT RETURNS NOTHING, which is why the cleanup is
    /// here (D-106 F-2 = A, kept for this fetcher — the note on the type
    /// says why). A dropped connection, a 429, a full disk or a
    /// cancel raised inside a file transfer all leave this method by the
    /// error path, and the bytes already written stay where the client
    /// put them: `base/models/<owner>/<name>`, nowhere near the weights
    /// directory the install would later move them to. Nothing above
    /// could see that path, so nothing above could remove it — a review
    /// found a 2.3 GB download that died at 90% sitting in a person's
    /// Documents forever, with `installState()` answering `.absent` and
    /// no code in this library able to clear it.
    ///
    /// It is worse than a leak, because the leftovers RESUME: the client
    /// writes its per-file bookkeeping inside that same tree, and its
    /// next run reuses a file whose commit hash still matches. That is
    /// option B — keep and resume — which D-106 rejected precisely
    /// because "resume" is a promise nobody here can test on a bad
    /// network. Deleting the tree deletes the bookkeeping with it, so the
    /// next attempt really does begin at zero.
    public func fetch(repoID: String,
                      into base: URL,
                      reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let hub = HubApi(downloadBase: base)
        do {
            return try await hub.snapshot(
                from: repoID,
                matching: LocalMindModel.weightGlobs
            ) { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        } catch {
            Self.discardPartialTree(repoID: repoID, under: base)
            throw error
        }
    }

    /// Where the client materialises `repoID` under `base` — ASKED of the
    /// client, never guessed. `localRepoLocation(_:)` is the same function
    /// `snapshot(from:matching:)` uses to decide where to write, so the
    /// two answers cannot drift apart; the note above this type is about
    /// what happens when code goes looking for a directory instead.
    static func snapshotLocation(repoID: String, under base: URL) -> URL {
        HubApi(downloadBase: base).localRepoLocation(Hub.Repo(id: repoID))
    }

    /// The fetcher's half of a throw, and since 5a of a delete: remove the
    /// tree this fetcher's client was writing into, and nothing else in
    /// `base` — other models live there, this demo's Whisper weights
    /// among them.
    ///
    /// The failure is swallowed: this runs while another error is already
    /// on its way to the caller, and a `removeItem` that could not is not
    /// the news.
    static func discardPartialTree(repoID: String, under base: URL) {
        try? FileManager.default.removeItem(at: snapshotLocation(repoID: repoID, under: base))
    }

    /// `deleteModel()`'s call (AC-295): the client's tree for this repo,
    /// bookkeeping and all.
    public func discard(repoID: String, under base: URL) async {
        Self.discardPartialTree(repoID: repoID, under: base)
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
    /// `deleteModel()` could not remove what it names (5a, AC-295), so
    /// `modelInstalled()` may still read true. The words are the file
    /// system's.
    case couldNotDelete(String)

    public var description: String {
        switch self {
        case .fetchFailed(let words):
            "the download failed: \(words)"
        case .couldNotComplete(let words):
            "the download arrived but could not be put in place: \(words)"
        case .sizeUnknown(let file):
            "the download size is unknown — the repository did not give a size for \(file)"
        case .couldNotDelete(let words):
            "the model could not be deleted: \(words)"
        }
    }
}
