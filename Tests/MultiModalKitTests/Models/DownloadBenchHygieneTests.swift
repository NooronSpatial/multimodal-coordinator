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
            if !server.acceptLoopEnded { stillRunning += 1 }
        }
        #expect(stillRunning == 0, "\(stillRunning) of 200 stops returned with the accept thread alive")
    }

    /// A watch the test has dropped must go: its dispatch source and its
    /// descriptor with it. A watch that holds itself leaks both, for the life
    /// of the test process.
    @Test("a dropped directory watch is freed, and gives back its descriptor")
    func aDroppedWatchIsFreed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bench-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var dropped: DirectoryWatch?
        do {
            let watch = try DirectoryWatch(directory)
            dropped = watch
        }
        #expect(dropped == nil, "the watch outlived the last reference to it")
    }
}
