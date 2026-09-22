import Foundation
// Does a BACKGROUND session download a real Hugging Face LFS file (which redirects to a CDN)?
final class D: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var size = -1; var status = -1; var failure: String?
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? -2
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failure = String(describing: error) }
        done.signal()
    }
}
let url = URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-base/AudioEncoder.mlmodelc/analytics/coremldata.bin")!
for (label, config) in [("background", URLSessionConfiguration.background(withIdentifier: "hfprobe.\(getpid())")),
                        ("default", URLSessionConfiguration.default)] {
    config.isDiscretionary = false
    let d = D()
    let session = URLSession(configuration: config, delegate: d, delegateQueue: nil)
    session.downloadTask(with: url).resume()
    _ = d.done.wait(timeout: .now() + 30)
    print("\(label): status \(d.status), \(d.size) bytes, error: \(d.failure ?? "none")")
    session.invalidateAndCancel()
}
