import Foundation

// PROBE: does the async convenience `download(for:)` work on a BACKGROUND URLSession?
// Serves a 1 MB file from a local HTTP server started beside this script.
let config = URLSessionConfiguration.background(withIdentifier: "probe.bg.\(getpid())")
config.isDiscretionary = false
let session = URLSession(configuration: config)
let url = URL(string: "http://127.0.0.1:8765/blob.bin")!
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let (file, response) = try await session.download(for: URLRequest(url: url))
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        print("ASYNC download(for:) on background session: OK, status \((response as? HTTPURLResponse)?.statusCode ?? -1), \(size) bytes")
    } catch {
        print("ASYNC download(for:) on background session: THREW \(error)")
    }
    semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + 20)
print("done")
