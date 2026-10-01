// 5d §233 — THE DOWNLOAD BENCH'S OWN HYGIENE (D-135).
//
// The 20× loops met descriptors closed under their owners twice — a file
// write that failed with a bad descriptor, a helper's output that came back
// empty — always in the download bench, never in the code it tests. Two
// patterns in the bench could close or touch a number nobody owns any more;
// each is proven here before it changes.

import Foundation
import Testing

@Suite("§233 · the download bench gives back what it holds", .timeLimit(.minutes(1)))
struct DownloadBenchHygieneTests {

    /// A server's listening socket is closed by `stop()`. If its accept thread
    /// is still alive then, the next `accept()` lands on a NUMBER the system
    /// may already have handed to another test's socket or file.
    @Test("stop() returns only once the accept thread has ended")
    func stopWaitsForTheAcceptThread() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bench-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var stillRunning = 0
        for _ in 0..<200 {
            let server = try LoopbackFileServer(directory: directory)
            server.stop()
            // Alive at the return, or alive when the socket was closed: the
            // second is the danger itself, and a stop that closed first and
            // waited after would hide behind the first check alone.
            if !server.acceptLoopEnded || server.acceptEndedAfterClose { stillRunning += 1 }
        }
        #expect(stillRunning == 0, "\(stillRunning) of 200 stops closed or returned with the accept thread alive")
    }

    /// A watch the test has dropped must go: its dispatch source and its
    /// descriptor with it. A watch that holds itself leaks both, for the life
    /// of the test process.
    ///
    /// The descriptor is closed by the source's cancel handler, on the
    /// source's queue — so the row waits for that EVENT, then asks the
    /// number what it holds. Closed, it holds nothing, or another's file;
    /// never this row's directory, whose name nobody else can have.
    @Test("a dropped directory watch is freed, and gives back its descriptor")
    func aDroppedWatchIsFreed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bench-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let closed = DispatchSemaphore(value: 0)
        weak var dropped: DirectoryWatch?
        let number: Int32
        do {
            let watch = try DirectoryWatch(directory) { closed.signal() }
            dropped = watch
            number = watch.descriptor
        }
        #expect(dropped == nil, "the watch outlived the last reference to it")
        #expect(closed.wait(timeout: .now() + 5) == .success, "the watch's source never ran its cancel handler")
        #expect(!Self.holds(number, directory), "descriptor \(number) still holds the watched directory")
    }

    /// Whether descriptor `number` is open on `directory`.
    static func holds(_ number: Int32, _ directory: URL) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(number, F_GETPATH, &path) != -1 else { return false }
        return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.hasSuffix(directory.lastPathComponent)
    }
}
