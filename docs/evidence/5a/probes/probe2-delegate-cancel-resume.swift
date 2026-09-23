import Foundation

// PROBE 2: a BACKGROUND URLSession with a delegate, in a plain process on this Mac:
//   (1) does the delegate see bytes? (2) cancel(byProducingResumeData:) → resume → 206 → complete file?
final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var written: [Int64] = []
    var finishedSize: Int = -1
    var resumeData: Data?
    var resumedAt: Int64 = -1
    var responseStatus = -1
    let done = DispatchSemaphore(value: 0)
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        written.append(totalBytesWritten)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        resumedAt = fileOffset
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finishedSize = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? -2
        responseStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? { resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data }
        done.signal()
    }
}
let config = URLSessionConfiguration.background(withIdentifier: "probe2.bg.\(getpid())")
config.isDiscretionary = false
let delegate = Delegate()
let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
let url = URL(string: "http://127.0.0.1:8766/blob.bin")!
let task = session.downloadTask(with: url)
task.resume()
// let some bytes land, then cancel with resume data
Thread.sleep(forTimeInterval: 1.5)
let cancelGroup = DispatchGroup(); cancelGroup.enter()
var producedResume: Data?
task.cancel { data in producedResume = data; cancelGroup.leave() }
cancelGroup.wait()
_ = delegate.done.wait(timeout: .now() + 10)
let partial = delegate.written.last ?? 0
print("(1) delegate saw \(delegate.written.count) writes, \(partial) bytes before the cancel; resume data: \(producedResume?.count ?? -1) bytes (via completion), \(delegate.resumeData?.count ?? -1) bytes (via error)")
guard let resume = producedResume ?? delegate.resumeData else { print("NO RESUME DATA"); exit(1) }
let d2 = Delegate()
let s2 = URLSession(configuration: URLSessionConfiguration.background(withIdentifier: "probe2.bg2.\(getpid())"), delegate: d2, delegateQueue: nil)
let t2 = s2.downloadTask(withResumeData: resume)
t2.resume()
_ = d2.done.wait(timeout: .now() + 30)
let expected = (try? FileManager.default.attributesOfItem(atPath: "blob.bin")[.size] as? Int) ?? -1
print("(2) resumed at offset \(d2.resumedAt), status \(d2.responseStatus), finished file \(d2.finishedSize) bytes (expected \(expected)) → \(d2.finishedSize == expected ? "COMPLETE" : "NOT complete")")
