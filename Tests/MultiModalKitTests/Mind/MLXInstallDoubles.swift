import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE DOUBLES 4x'S INSTALL ROWS SHARE (SPEC §181/3, AC-249).
//
// Before 4x the fetch was an internal closure typealias, so every fake
// was a bare `{ _, _, _ in ... }` written inline. AC-249 makes the seam
// a PUBLIC protocol — the one Aura conforms to for its download screen —
// so the fakes become types, and they live here because three suites
// need the same two.
//
// Nothing here touches the network. Every row runs in a temporary
// directory with a few kilobytes of 0x2A.

/// A fetcher made of a closure — the shape the 4v rows were written in,
/// kept working now that `WeightsFetching` is a protocol. It is also the
/// smallest possible proof that the protocol is fakeable by a caller who
/// is not this library.
struct FakeWeightsFetcher: WeightsFetching {
    let body: @Sendable (String, URL, @escaping @Sendable (Double) -> Void) async throws -> URL

    init(_ body: @escaping @Sendable (String, URL, @escaping @Sendable (Double) -> Void) async throws -> URL) {
        self.body = body
    }

    func fetch(repoID: String,
               into base: URL,
               reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await body(repoID, base, progress)
    }
}

/// ONE OBJECT THAT RECORDS BOTH QUESTIONS — the size question and the
/// download question — because AC-246 is a claim about something that
/// does NOT happen, and a fake nobody can reach proves nothing.
///
/// The recorder answers `expectedInstall`'s sizing seam AND conforms to
/// `WeightsFetching`, writing both kinds of call into one log. So the
/// AC-246 row can show the log holding a size call and no fetch, and
/// then, with the SAME recorder, show a fetch being recorded when a
/// download really happens. The absence in the first half is evidence,
/// not a vacuum.
final class RecordingInstallSource: WeightsFetching, Sendable {
    /// What was asked of it, in order.
    enum Call: Equatable, Sendable {
        case sizes(String)
        case fetch(String)
    }

    private let log = Mutex<[Call]>([])
    private let answer: [InstallSize.FileSize]
    private let places: URL?
    /// Thrown instead of answering the size question, when a row wants
    /// the failure path.
    private let sizeError: (any Error)?

    init(answering files: [InstallSize.FileSize] = [],
         placing snapshot: URL? = nil,
         failingWith sizeError: (any Error)? = nil) {
        self.answer = files
        self.places = snapshot
        self.sizeError = sizeError
    }

    var calls: [Call] { log.withLock { $0 } }

    /// The size seam, as a closure the model will accept.
    var sizing: LocalMindModel.Sizing {
        { [self] repoID, _ in
            log.withLock { $0.append(.sizes(repoID)) }
            if let sizeError { throw sizeError }
            return answer
        }
    }

    func fetch(repoID: String,
               into base: URL,
               reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        log.withLock { $0.append(.fetch(repoID)) }
        let snapshot = places ?? base.appending(path: "snapshot")
        try InstallScratch.tree(at: snapshot)
        progress(1)
        return snapshot
    }
}

/// The temporary directories and the small trees every install row uses.
enum InstallScratch {
    /// A fresh directory. The caller removes it.
    static func directory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The four files `modelInstalled()` has always required, with known
    /// bytes — the sizes the manifest will remember.
    static func tree(at directory: URL, weightBytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in [("config.json", 32), ("tokenizer.json", 64),
                              ("tokenizer_config.json", 16), ("model.safetensors", weightBytes)] {
            try Data(repeating: 0x2A, count: bytes).write(to: directory.appending(path: name))
        }
    }

    /// Whether a directory carries the backup exclusion (AC-250). `false`
    /// when the path does not exist or the filesystem will not say.
    ///
    /// The URL is rebuilt from the path so this reads the DISK. A `URL`
    /// caches resource values it has already fetched, and copies share
    /// that cache; a test that asks "did the flag really change?" must not
    /// be answered from a memory of the last answer.
    static func excludedFromBackup(_ url: URL) -> Bool {
        (try? URL(filePath: url.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    /// Sets the flag back to `false` by hand — AC-250's "delete the flag"
    /// half, so the re-download has something to restore.
    ///
    /// AND IT DELETES THE ATTRIBUTE ITSELF, because the API alone is not
    /// reliable in this direction — measured, not guessed. A harness ran
    /// the exact set/clear sequence this row uses: turning the exclusion
    /// ON stuck 4000 times out of 4000, and turning it OFF silently did
    /// nothing 3 times in 2000, with `setResourceValues` returning success
    /// and the attribute still on disk. That ~0.15% is what made this
    /// suite flake roughly once in forty runs, on this commit and on the
    /// one before it. Removing the attribute by hand afterwards closed it:
    /// 0 stuck out of 14 in the same harness, every time.
    ///
    /// Only the CLEAR is unreliable, and only a test ever clears — the
    /// library exclusively sets the flag ON, which is the direction that
    /// never missed. So this is a test-harness repair, not a cover for a
    /// library bug; the number is written down here so the next person
    /// does not have to find it again.
    ///
    /// A missing attribute is not an error: `removexattr` answers
    /// `ENOATTR` when the flag was already gone, which is the state this
    /// function is asking for.
    static func clearBackupExclusion(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
        _ = url.path.withCString { path in
            removexattr(path, "com.apple.metadata:com_apple_backup_excludeItem", 0)
        }
    }
}

/// The house wait: an event racing a `Task.sleep` cap, never a poll and
/// never a bare sleep — the same shape `ReplyContractTests` uses.
final class InstallSignals: Sendable {
    private let stream: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation
    init() {
        (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }
    func send(_ name: String) { emit.yield(name) }
    /// True when `name` arrives before the deadline. The loser of the race
    /// is cancelled, never abandoned.
    func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await event in stream where event == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
