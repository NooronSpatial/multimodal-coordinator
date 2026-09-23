import Foundation
// PROBE 3: relaunch re-entry on this Mac. Run as `probe3 start` (starts a download in a background
// session and EXITS at once), then `probe3 attach` (a new process, same identifier: does the file arrive?)
final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var finishedSize = -1; var status = -1; var resumedAt: Int64 = -1
    let done = DispatchSemaphore(value: 0)
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finishedSize = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? -2
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { print("  completed with error: \(error)") }
        done.signal()
    }
}
let identifier = "probe3.bg.fixed"
let config = URLSessionConfiguration.background(withIdentifier: identifier)
config.isDiscretionary = false
let delegate = Delegate()
let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
if CommandLine.arguments.contains("start") {
    let task = session.downloadTask(with: URL(string: "http://127.0.0.1:8767/blob.bin")!)
    task.taskDescription = "destination=/tmp/whatever"
    task.resume()
    Thread.sleep(forTimeInterval: 0.5)
    print("started task \(task.taskIdentifier) and exiting the process now")
    exit(0)
} else {
    let group = DispatchGroup(); group.enter()
    var count = -1; var descriptions: [String] = []
    session.getAllTasks { tasks in count = tasks.count; descriptions = tasks.compactMap(\.taskDescription); group.leave() }
    group.wait()
    print("  new process sees \(count) task(s) in session '\(identifier)': \(descriptions)")
    let waited = delegate.done.wait(timeout: .now() + 40)
    print("  re-entry: \(waited == .success ? "delegate fired" : "TIMED OUT") — status \(delegate.status), file \(delegate.finishedSize) bytes, expected \((try? FileManager.default.attributesOfItem(atPath: "blob.bin")[.size] as? Int) ?? -1)")
}
