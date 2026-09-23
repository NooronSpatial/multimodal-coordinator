import Foundation
import Synchronization

// THE DOWNLOADER (5a, SPEC §202, D-114 F-1 = A, F-3 = A, F-4 = A,
// F-8 = A): one actor over ONE background `URLSession`, moving plans.
//
// Why it exists, in one measured sentence: the vendors' own
// "background session" switch CRASHES (the Hub client calls the async
// convenience on a background session, and the system refuses it —
// docs/evidence/5a/probes/probe1.out.txt), so a transfer that goes on
// while the app is suspended or dead has to be a downloader this
// library owns. This is it, and every engine that downloads goes
// through it with its own catalog.
//
// The life of one transfer, as it runs:
//
//   transfer(plan) ─► complete files skipped ─► in-flight tasks ADOPTED
//                  ─► resume data → downloadTask(withResumeData:)
//                  ─► the rest → downloadTask(with:)      (all enqueued at once)
//                  ─► await, as a waiter
//   the daemon moves bytes; the relay (the delegate) turns its calls into
//   EVENTS, in order; the actor turns events into fractions, landings,
//   failures, and the waiters' answers.
//
// THE ONE ISLAND (§4.1): `URLSession` calls its delegate on a serial
// queue of its own, and the temporary file it hands `didFinishDownloadingTo`
// is deleted when that call returns — so the delegate is a small
// `@unchecked Sendable` class that moves the file synchronously and
// emits an event. The events reach the actor through a CHAIN of tasks,
// each awaiting the one before, so the order the daemon spoke in is the
// order the actor hears. That chain is the one unstructured `Task` in
// this file, and this paragraph is its proof: the delegate's world is
// not structured concurrency, and the bridge has to be built from the
// far side.

/// Moves `DownloadPlan`s on a background session — the one object every
/// downloadable engine's `ensureModel(progress:)` goes through.
///
/// `shared` is the library's session (`ModelDownloads.sessionIdentifier`);
/// the system allows one live session per identifier per process, which
/// is why there is one. An app that needs a second session — an
/// extension, say — builds its own with `init(sessionIdentifier:)`.
public actor ModelDownloader {
    /// The library's downloader, on its background session.
    public static let shared = ModelDownloader(configuration: ModelDownloads.backgroundConfiguration())

    private let session: URLSession
    private let relay: TransferRelay
    /// Plans in flight, by `DownloadPlan.key`.
    private var transfers: [String: Transfer] = [:]
    /// Destination path → the key of the transfer it belongs to.
    private var owners: [String: String] = [:]
    /// Tasks whose landing this actor has processed and whose completion
    /// has not yet arrived — never adopted, never listened to again (the
    /// note on `handle`).
    private var landedTasks: Set<Int> = []
    /// The app's completion handler for a background wake-up (AC-297),
    /// waiting for the session to say its events are done.
    private var wakeUp: (@Sendable () -> Void)?
    private var eventsFinished = false

    /// A background session of this name. Use it only for a session the
    /// library's `shared` cannot be — the same identifier twice in one
    /// process is the system's error, not this library's.
    public init(sessionIdentifier: String) {
        self.init(configuration: ModelDownloads.backgroundConfiguration(identifier: sessionIdentifier))
    }

    /// Any configuration — the tests' door, and `shared`'s.
    init(configuration: URLSessionConfiguration) {
        let relay = TransferRelay()
        self.relay = relay
        self.session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        relay.owner = self
    }

    // MARK: - the public doors

    /// Moves every file of `plan` that is not already complete, reporting
    /// one fraction for the whole plan — Σ bytes written ÷ Σ bytes
    /// expected — never decreasing, and `1.0` exactly once, last
    /// (AC-291). A plan whose files are all complete says `1.0` once and
    /// asks the network nothing.
    ///
    /// A second call with the same destinations while one runs JOINS it
    /// (AC-296): one transfer, every caller's closure fed. Cancelling the
    /// calling task cancels this caller at once; the transfer itself
    /// stops when the LAST waiter has gone (F-8 = A), keeping what can be
    /// resumed beside each destination (F-4 = A) — and the next call
    /// resumes from it.
    ///
    /// - Throws: `CancellationError` when this caller was cancelled;
    ///   `DownloadFailure` when the bytes could not be moved or placed.
    public func transfer(_ plan: DownloadPlan,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let key = plan.key
        // THE REENTRANCY LAW, in a loop: every `await` below may have
        // changed `transfers`, so the question is asked again after each.
        while let existing = transfers[key] {
            if existing.cancelling {
                // The last waiter just left and the tasks are being
                // cancelled; a fresh transfer would adopt tasks that are
                // dying. Wait for the dust to settle, then look again.
                await settle(of: existing)
                continue
            }
            return try await wait(on: existing, key: key, progress: progress)
        }

        let transfer = Transfer(plan: plan)
        guard !transfer.allComplete else {
            progress(1.0)
            return
        }

        // Tasks the daemon may still be running from an earlier process
        // (AC-292) — adopted by their description, never duplicated.
        let inFlight = await downloadTasks()
        if let existing = transfers[key] {
            // Somebody built the same transfer during that await.
            guard !existing.cancelling else { return try await self.transfer(plan, progress: progress) }
            return try await wait(on: existing, key: key, progress: progress)
        }
        // A destination discarded by a delete is a destination again.
        relay.reinstate(transfer.files.map(\.file.destination.path))
        for index in transfer.files.indices where !transfer.files[index].done {
            let file = transfer.files[index].file
            let path = file.destination.path
            if let running = inFlight.first(where: {
                $0.taskDescription == path && $0.state != .completed && !landedTasks.contains($0.taskIdentifier)
            }) {
                transfer.files[index].task = running
                transfer.files[index].written = running.countOfBytesReceived
                if running.countOfBytesExpectedToReceive > 0, transfer.files[index].expected == nil {
                    transfer.files[index].expected = running.countOfBytesExpectedToReceive
                }
                continue
            }
            try? FileManager.default.createDirectory(at: file.destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: file.resumeDataURL) {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: file.source)
            }
            task.taskDescription = path
            transfer.files[index].task = task
            task.resume()
        }
        transfers[key] = transfer
        for file in transfer.files { owners[file.file.destination.path] = key }
        return try await wait(on: transfer, key: key, progress: progress)
    }

    /// Stops any transfer of these files without keeping anything —
    /// the delete's half (AC-295): tasks cancelled outright, resume data
    /// removed, every waiter told `CancellationError`. The files
    /// themselves are the engine's to remove; it knows what it wrote.
    public func discard(_ plan: DownloadPlan) async {
        let key = plan.key
        // TOLD BEFORE CANCELLED, and the order is the mechanism. A task
        // whose bytes have all arrived is past cancelling: its landing is
        // already on its way to the relay, on the session's own queue,
        // and the relay would move the file into a scratch directory the
        // caller is about to remove — recreating it with one small file
        // inside. (A row deleting mid-transfer found the scratch back on
        // disk with `config.json` in it.) So the relay is told first,
        // and a landing for a discarded destination is left to die with
        // its temporary file.
        relay.discard(plan.files.map(\.destination.path))
        if let transfer = transfers.removeValue(forKey: key) {
            for file in transfer.files {
                file.task?.cancel()
                owners[file.file.destination.path] = nil
            }
            transfer.resumeEveryone(throwing: CancellationError())
        }
        // A task the daemon carried over from an earlier process, with
        // no transfer object here to own it.
        let paths = Set(plan.files.map(\.destination.path))
        for task in await downloadTasks() where paths.contains(task.taskDescription ?? "") {
            task.cancel()
        }
        for file in plan.files { try? FileManager.default.removeItem(at: file.resumeDataURL) }
    }

    /// Is a transfer of this plan alive right now — not settled, not
    /// being cancelled? The tests' question.
    func isTransferring(_ plan: DownloadPlan) -> Bool {
        guard let transfer = transfers[plan.key] else { return false }
        return !transfer.cancelling
    }

    /// The re-entry door's other half (AC-297): the app was woken for
    /// this session's events; `completion` is called on the main thread
    /// once the session says they have all been delivered — or at once,
    /// if it already said so. `ModelDownloads.handleEvents` calls this on
    /// `shared`; an app with its own session calls it on that session's
    /// downloader.
    public func handleEvents(completion: @escaping @Sendable () -> Void) {
        if eventsFinished {
            eventsFinished = false
            Task { @MainActor in completion() }
        } else {
            wakeUp = completion
        }
    }

    /// Ends the session — the tests' teardown. A live session holds its
    /// delegate, and a test that made forty sessions should not leave
    /// forty relays behind.
    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - waiting

    /// Registers `progress` and waits for the transfer's ending.
    private func wait(on transfer: Transfer, key: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let id = transfer.addWaiter(progress)
        // A joiner sees where the transfer already is, so its bar does
        // not start at nothing while bytes have long been arriving — and
        // so does the first waiter on an ADOPTED task, whose bytes were
        // reported to a process that is gone (AC-292): the fraction is
        // computed from the task's own count, not waited for.
        let fraction = transfer.fraction
        if fraction > 0, fraction < 1 {
            transfer.lastFraction = max(transfer.lastFraction, fraction)
            progress(fraction)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                transfer.waiters[id]?.continuation = continuation
            }
        } onCancel: {
            // The handler may not await, so the hop to the actor is a
            // task — the same bridge the relay uses, for the same reason.
            Task { await self.leave(key: key, waiter: id) }
        }
    }

    /// A waiter's task was cancelled. Not the last: answered at once.
    /// The last (F-8 = A): every task is cancelled WITH resume data, and
    /// the waiter is answered when their completions have all arrived —
    /// so that when `transfer` throws, the resume data is on disk.
    private func leave(key: String, waiter id: Int) {
        guard let transfer = transfers[key], let waiter = transfer.waiters.removeValue(forKey: id) else { return }
        guard transfer.waiters.isEmpty else {
            waiter.continuation?.resume(throwing: CancellationError())
            return
        }
        transfer.cancelling = true
        if let continuation = waiter.continuation { transfer.cancelled.append(continuation) }
        for file in transfer.files where !file.done {
            file.task?.cancel(byProducingResumeData: { _ in })
        }
        settleIfQuiet(transfer, key: key)
    }

    /// Waits, on the actor, for a cancelling transfer to be forgotten.
    private func settle(of transfer: Transfer) async {
        await withCheckedContinuation { transfer.settleWaiters.append($0) }
    }

    /// A cancelling transfer whose tasks have all reported in is gone:
    /// its cancelled waiters throw, and anyone waiting for the dust to
    /// settle looks again.
    private func settleIfQuiet(_ transfer: Transfer, key: String) {
        guard transfer.cancelling, transfer.files.allSatisfy({ $0.task == nil || $0.done }) else { return }
        forget(transfer, key: key)
        for continuation in transfer.cancelled { continuation.resume(throwing: CancellationError()) }
        transfer.cancelled.removeAll()
        for continuation in transfer.settleWaiters { continuation.resume() }
        transfer.settleWaiters.removeAll()
    }

    private func forget(_ transfer: Transfer, key: String) {
        transfers[key] = nil
        for file in transfer.files { owners[file.file.destination.path] = nil }
    }

    // MARK: - the daemon's words, in order

    /// One event from the relay. Every branch names the file by its
    /// destination, which is what a task carries as its description —
    /// the only name that survives a relaunch. A landing or a write with
    /// no transfer to own it is a file the daemon finished for an
    /// earlier process: it is in place, and the next `transfer` finds it
    /// complete. Nothing to do.
    ///
    /// AND ONLY THE FILE'S OWN TASK IS HEARD. A landed task's completion
    /// arrives AFTER its landing — after the waiters were answered — so
    /// a caller that comes straight back (a file damaged and fetched
    /// again; a delete and a fresh download) finds the old task still in
    /// the session, not yet completed. It must be neither adopted nor
    /// listened to: adopted, its completion would clear the file's task
    /// with no landing ever to follow (a row hung for its full minute on
    /// exactly that — `docs/evidence/5a`); listened to, its words would
    /// move the fresh task's state. So every event names its task, the
    /// actor keeps the identifiers of tasks whose landing it has already
    /// processed, and a task that is not the file's current one is heard
    /// by nobody.
    func handle(_ event: TransferRelay.Event) {
        guard let (path, task) = event.speaker else {
            sessionFinishedEvents()
            return
        }
        if case .completed = event { landedTasks.remove(task) }
        guard let found = locate(path), found.transfer.files[found.index].task?.taskIdentifier == task else { return }
        switch event {
        case .wrote(_, _, let written, let expected):
            wrote(found, written: written, expected: expected)
        case .landed(_, _, let bytes):
            landedTasks.insert(task)
            landed(found, bytes: bytes)
        case .couldNotPlace(_, _, let words):
            fail(found.transfer, key: found.key, with: .couldNotPlace(file: found.file.name, words))
        case .refused(_, _, let status):
            found.transfer.files[found.index].task = nil
            fail(found.transfer, key: found.key,
                 with: .transferFailed(file: found.file.name, "the server answered \(status)"))
        case .completed(_, _, let error, let resumeData):
            completed(found, error: error, resumeData: resumeData)
        case .finishedEvents:
            break
        }
    }

    /// The session has delivered every event it held for a wake-up: the
    /// app's completion handler is called, on the main thread — or, if
    /// none was handed over yet, remembered for the one that will be.
    private func sessionFinishedEvents() {
        if let completion = wakeUp {
            wakeUp = nil
            Task { @MainActor in completion() }
        } else {
            eventsFinished = true
        }
    }

    /// Bytes arrived: the plan's fraction moves, and every waiter hears
    /// it — only upward, and never `1.0`, which is the landing's word.
    private func wrote(_ found: Located, written: Int64, expected: Int64) {
        let transfer = found.transfer
        transfer.files[found.index].written = written
        if expected > 0, transfer.files[found.index].expected == nil { transfer.files[found.index].expected = expected }
        let fraction = transfer.fraction
        guard fraction > transfer.lastFraction, fraction < 1 else { return }
        transfer.lastFraction = fraction
        for waiter in transfer.waiters.values { waiter.progress(fraction) }
    }

    /// A file is in place. Short of its declared size, it is removed and
    /// the plan fails; otherwise it is done, and when every file is, the
    /// waiters hear `1.0` once and return.
    private func landed(_ found: Located, bytes: Int64) {
        let transfer = found.transfer
        let file = found.file
        if let expected = file.expectedBytes, bytes != expected {
            try? FileManager.default.removeItem(at: file.destination)
            fail(transfer, key: found.key, with: .shortFile(file: file.name, got: bytes, expected: expected))
            return
        }
        try? FileManager.default.removeItem(at: file.resumeDataURL)
        transfer.files[found.index].done = true
        transfer.files[found.index].written = bytes
        // The task stays named until its completion arrives, so that the
        // completion is recognised as this file's — and not adopted by a
        // transfer that comes straight back for the same destination.
        if transfer.files[found.index].expected == nil { transfer.files[found.index].expected = bytes }
        guard transfer.allComplete else {
            settleIfQuiet(transfer, key: found.key)
            return
        }
        forget(transfer, key: found.key)
        transfer.lastFraction = 1
        for waiter in transfer.waiters.values {
            waiter.progress(1.0)
            waiter.continuation?.resume()
        }
        transfer.waiters.removeAll()
    }

    /// A task ended. With resume data — a cancel or a failure — what can
    /// be resumed is kept beside the destination (F-4 = A). A cancel is
    /// the last waiter's doing and settles; a failure ends the plan.
    private func completed(_ found: Located, error: (any Error)?, resumeData: Data?) {
        let transfer = found.transfer
        if let resumeData {
            try? resumeData.write(to: found.file.resumeDataURL)
        }
        transfer.files[found.index].task = nil
        guard let error else { return }   // the landing already said everything
        if (error as NSError).code == NSURLErrorCancelled {
            settleIfQuiet(transfer, key: found.key)
            return
        }
        fail(transfer, key: found.key, with: .transferFailed(file: found.file.name, String(describing: error)))
    }

    /// A file, found by its destination: the transfer it belongs to and
    /// its index there.
    private struct Located {
        let transfer: Transfer
        let key: String
        let index: Int
        var file: DownloadPlan.File { transfer.files[index].file }
    }

    private func locate(_ path: String) -> Located? {
        guard let key = owners[path], let transfer = transfers[key],
              let index = transfer.files.firstIndex(where: { $0.file.destination.path == path }) else { return nil }
        return Located(transfer: transfer, key: key, index: index)
    }

    /// One file's failure ends the plan for its waiters. The other files'
    /// tasks are NOT cancelled: the daemon finishes them and they land in
    /// place, so the next attempt has less to do (F-4 = A's spirit).
    private func fail(_ transfer: Transfer, key: String, with failure: DownloadFailure) {
        forget(transfer, key: key)
        transfer.resumeEveryone(throwing: failure)
    }

    /// The session's download tasks, asked of the session.
    private func downloadTasks() async -> [URLSessionDownloadTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap { $0 as? URLSessionDownloadTask })
            }
        }
    }
}

// MARK: - one transfer's state (actor-isolated, never leaves the actor)

extension ModelDownloader {
    /// One file of a plan in flight.
    struct FileState {
        let file: DownloadPlan.File
        var task: URLSessionDownloadTask?
        var written: Int64 = 0
        var expected: Int64?
        var done = false
    }

    /// One caller of `transfer`, waiting.
    struct Waiter {
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<Void, any Error>?
    }

    /// A plan in flight: its files, its waiters, its ending.
    final class Transfer {
        let plan: DownloadPlan
        var files: [FileState]
        var waiters: [Int: Waiter] = [:]
        private var nextWaiter = 0
        var lastFraction: Double = 0
        /// The last waiter left; the tasks are being cancelled.
        var cancelling = false
        /// The last waiter's continuation, answered once settled.
        var cancelled: [CheckedContinuation<Void, any Error>] = []
        /// Callers of `transfer` waiting for a cancelling transfer to go.
        var settleWaiters: [CheckedContinuation<Void, Never>] = []

        init(plan: DownloadPlan) {
            self.plan = plan
            self.files = plan.files.map { file in
                var state = FileState(file: file, expected: file.expectedBytes)
                if let size = Self.sizeOnDisk(file.destination),
                   file.expectedBytes == nil || file.expectedBytes == size {
                    state.done = true
                    state.written = size
                    state.expected = size
                }
                return state
            }
        }

        var allComplete: Bool { files.allSatisfy(\.done) }

        /// Σ written ÷ Σ expected, over the files whose total is known.
        var fraction: Double {
            let known = files.filter { $0.expected != nil }
            let expected = known.reduce(Int64(0)) { $0 + ($1.expected ?? 0) }
            guard expected > 0 else { return 0 }
            let written = known.reduce(Int64(0)) { $0 + min($1.written, $1.expected ?? 0) }
            return min(1, Double(written) / Double(expected))
        }

        func addWaiter(_ progress: @escaping @Sendable (Double) -> Void) -> Int {
            nextWaiter += 1
            waiters[nextWaiter] = Waiter(progress: progress)
            return nextWaiter
        }

        func resumeEveryone(throwing error: any Error) {
            for waiter in waiters.values { waiter.continuation?.resume(throwing: error) }
            waiters.removeAll()
            for continuation in cancelled { continuation.resume(throwing: error) }
            cancelled.removeAll()
            for continuation in settleWaiters { continuation.resume() }
            settleWaiters.removeAll()
        }

        private static func sizeOnDisk(_ url: URL) -> Int64? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
    }
}

// MARK: - the relay: the delegate, turned into ordered events

/// The session's delegate. `@unchecked Sendable` with the proof from the
/// file's header: `URLSession` calls it on ONE serial queue; its only
/// state is the task chain under a `Mutex` and a weak owner; the one
/// piece of work it does itself — moving the landed file — is
/// synchronous and must be, because the temporary file dies when
/// `didFinishDownloadingTo` returns.
final class TransferRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case wrote(destination: String, task: Int, written: Int64, expected: Int64)
        case landed(destination: String, task: Int, bytes: Int64)
        case couldNotPlace(destination: String, task: Int, words: String)
        case refused(destination: String, task: Int, status: Int)
        case completed(destination: String, task: Int, error: (any Error)?, resumeData: Data?)
        case finishedEvents

        /// The file the event is about and the task that spoke — `nil`
        /// for the session's own word. THE TASK IS CHECKED, not only the
        /// file: a file can have had two tasks in one process — one that
        /// landed and whose completion is still on its way, and a fresh
        /// one for the same destination — and the words of the old one
        /// must not move the new one's state (the note on `handle`).
        var speaker: (destination: String, task: Int)? {
            switch self {
            case .wrote(let path, let task, _, _), .landed(let path, let task, _),
                 .couldNotPlace(let path, let task, _), .refused(let path, let task, _),
                 .completed(let path, let task, _, _): (path, task)
            case .finishedEvents: nil
            }
        }
    }

    weak var owner: ModelDownloader?
    /// The chain: each event's task awaits the previous one, so the
    /// actor hears the events in the order the session spoke them.
    private let chain = Mutex<Task<Void, Never>?>(nil)
    /// Destinations a delete has discarded: a landing for one of these
    /// is not moved into place (the note on `ModelDownloader.discard`).
    private let discarded = Mutex<Set<String>>([])

    func discard(_ destinations: [String]) {
        discarded.withLock { $0.formUnion(destinations) }
    }

    func reinstate(_ destinations: [String]) {
        discarded.withLock { $0.subtract(destinations) }
    }

    private func emit(_ event: Event) {
        guard let owner else { return }
        chain.withLock { previous in
            let earlier = previous
            previous = Task {
                await earlier?.value
                await owner.handle(event)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let path = downloadTask.taskDescription else { return }
        emit(.wrote(destination: path, task: downloadTask.taskIdentifier,
                    written: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard let path = downloadTask.taskDescription else { return }
        emit(.wrote(destination: path, task: downloadTask.taskIdentifier,
                    written: fileOffset, expected: expectedTotalBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let path = downloadTask.taskDescription else { return }
        // A landing for a discarded destination dies here, with its
        // temporary file — the scratch it would land in is being removed.
        guard !discarded.withLock({ $0.contains(path) }) else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            // An error page is not a model file. The temporary file is
            // left to die with this call.
            emit(.refused(destination: path, task: downloadTask.taskIdentifier, status: status))
            return
        }
        let destination = URL(fileURLWithPath: path)
        let files = FileManager.default
        do {
            try files.createDirectory(at: destination.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: location, to: destination)
            let bytes = (try? files.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            emit(.landed(destination: path, task: downloadTask.taskIdentifier, bytes: bytes))
        } catch {
            emit(.couldNotPlace(destination: path, task: downloadTask.taskIdentifier, words: String(describing: error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let path = task.taskDescription else { return }
        let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        emit(.completed(destination: path, task: task.taskIdentifier, error: error, resumeData: resumeData))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        emit(.finishedEvents)
    }
}
