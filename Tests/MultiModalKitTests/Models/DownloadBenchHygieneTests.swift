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

    /// The case that matters: a server that has SERVED, so its accept thread
    /// is back in `accept()`, waiting. On this Mac `shutdown()` does not wake
    /// that wait — only `close()` does (5d §233, the experiment) — so a stop
    /// that closes only after the thread has ended must wake it another way.
    @Test("a server that has served stops with its accept thread ended before its socket closes")
    func aServedServerStopsCleanly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bench-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("served".utf8).write(to: directory.appending(path: "f.bin"))
        var lateEnds = 0
        for _ in 0..<3 {
            let server = try LoopbackFileServer(directory: directory)
            #expect(Self.fetch("f.bin", from: server.port) == "served", "the server served")
            server.stop()
            if !server.acceptLoopEnded || server.acceptEndedAfterClose { lateEnds += 1 }
        }
        #expect(lateEnds == 0, "\(lateEnds) of 3 stops closed the socket under a waiting accept thread")
    }

    /// One plain GET over a blocking socket: the response's body. The server
    /// answers `Connection: close`, so its close ends the read — an event; the
    /// receive cap only keeps a broken server from hanging the row.
    static func fetch(_ path: String, from port: UInt16) -> String? {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }
        defer { close(client) }
        var cap = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &cap, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request = Array("GET /\(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        guard send(client, request, request.count, 0) == request.count else { return nil }
        var response: [UInt8] = []
        var piece = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(client, &piece, piece.count)
            guard count > 0 else { break }
            response += piece[0..<count]
        }
        let text = String(decoding: response, as: UTF8.self)
        guard let head = text.range(of: "\r\n\r\n") else { return nil }
        return String(text[head.upperBound...])
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
