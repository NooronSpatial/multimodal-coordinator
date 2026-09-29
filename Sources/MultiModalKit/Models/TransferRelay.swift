// THE RELAY — the download delegate, turned into ordered events for the
// `ModelDownloader` actor. Moved to its own file unchanged (§222): the
// downloader's file had reached the lint's length.

import Foundation
import Synchronization

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
