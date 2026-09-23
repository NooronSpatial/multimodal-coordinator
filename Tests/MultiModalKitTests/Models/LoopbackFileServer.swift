import Foundation
import Synchronization

// THE LOOPBACK SERVER (5a, SPEC §203) — the instrument every downloader
// row measures against.
//
// A real `URLSession` moving real bytes over a real socket is the only
// honest test of a downloader; a fake transport would test the fake.
// So this is a small HTTP/1.1 server on 127.0.0.1, serving the files in
// one directory, and it does three things a public server would not:
//
//   - it COUNTS — requests per path, bytes sent per path, `Range`
//     requests per path — so "one request per file" (AC-296) and "never
//     twice the file" (AC-293) are numbers read from the server;
//   - it answers `Range: bytes=N-` with `206` and `Content-Range`, the
//     way huggingface.co does, so a resume is a resume;
//   - it can HOLD a transfer at a byte the test names: the connection
//     sends that many bytes and then waits until the test says
//     `release()`. That is how a cancel lands mid-file WITHOUT a sleep —
//     the test waits for the server to say it has parked, cancels, and
//     only then lets the server go on. Events, never timing.
//
// POSIX sockets and one thread per connection, on purpose: this Mac's
// `NWListener` refuses to listen from a test process (EINVAL, every
// variant tried), and a server that cannot start is no instrument.
// Blocking reads and writes on their own threads are the oldest
// reliable shape there is, and a test double may use threads.
//
// `@unchecked Sendable`: every mutable field is under one `Mutex`, and
// the lock is never held across a blocking call.
final class LoopbackFileServer: @unchecked Sendable {
    struct Counts: Equatable {
        var requests = 0
        var rangeRequests = 0
        var bytesSent = 0
        var firstRangeOffset: Int?
    }

    private struct State {
        var counts: [String: Counts] = [:]
        /// Path → the byte count after which a connection parks.
        var holds: [String: Int] = [:]
        /// Path → the byte count after which the connection is dropped.
        var drops: [String: Int] = [:]
        /// Parked connections, each waiting on its own semaphore.
        var parked: [DispatchSemaphore] = []
        /// Who is waiting to hear that a connection has parked.
        var parkedWatchers: [CheckedContinuation<Void, Never>] = []
        var stopped = false
    }

    private let directory: URL
    private let socket: Int32
    private let state = Mutex(State())
    let port: UInt16

    init(directory: URL) throws {
        self.directory = directory
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw LoopbackFailure.couldNotListen("socket: \(errno)") }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) }
        }
        guard bound == 0 else { close(socket); throw LoopbackFailure.couldNotListen("bind: \(errno)") }
        guard listen(socket, 16) == 0 else { close(socket); throw LoopbackFailure.couldNotListen("listen: \(errno)") }
        var boundAddress = sockaddr_in()
        var boundLength = length
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &boundLength) }
        }
        self.socket = socket
        self.port = UInt16(bigEndian: boundAddress.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "loopback-file-server"
        thread.start()
    }

    enum LoopbackFailure: Error { case couldNotListen(String) }

    func stop() {
        state.withLock { $0.stopped = true }
        release()
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    func counts(for path: String) -> Counts {
        state.withLock { $0.counts[path] ?? Counts() }
    }

    /// The connection serving `path` sends `bytes` and then parks until
    /// `release()`.
    func hold(_ path: String, after bytes: Int) {
        state.withLock { $0.holds[path] = bytes }
    }

    /// The connection serving `path` sends `bytes` and then closes the
    /// socket without finishing — a dropped connection.
    func drop(_ path: String, after bytes: Int) {
        state.withLock { $0.drops[path] = bytes }
    }

    /// Lets every parked connection go on, and forgets the holds.
    func release() {
        let parked = state.withLock { state -> [DispatchSemaphore] in
            state.holds.removeAll()
            let parked = state.parked
            state.parked.removeAll()
            return parked
        }
        for semaphore in parked { semaphore.signal() }
    }

    /// Waits until a connection has parked — the event a test gates on
    /// before it cancels.
    func parkedConnection() async {
        await withCheckedContinuation { continuation in
            let parkedAlready = state.withLock { state -> Bool in
                if state.parked.isEmpty {
                    state.parkedWatchers.append(continuation)
                    return false
                }
                return true
            }
            if parkedAlready { continuation.resume() }
        }
    }

    // MARK: - the threads

    private func acceptLoop() {
        while !state.withLock({ $0.stopped }) {
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "loopback-file-server-connection"
            thread.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let request = readRequest(client) else { return }
        // The query is not part of the file: `tree/main?recursive=true`
        // serves `tree/main`, the way a listing endpoint is asked.
        let path = String(request.target.prefix { $0 != "?" }.drop(while: { $0 == "/" }))
        let file = directory.appending(path: path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int),
              let handle = try? FileHandle(forReadingFrom: file) else {
            _ = write(client, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        defer { try? handle.close() }

        var start = 0
        var status = "200 OK"
        var extra = ""
        if let range = request.range {
            start = min(range, size)
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(start)-\(size - 1)/\(size)\r\n"
        }
        state.withLock { state in
            var counts = state.counts[path, default: Counts()]
            counts.requests += 1
            if request.range != nil {
                counts.rangeRequests += 1
                if counts.firstRangeOffset == nil { counts.firstRangeOffset = start }
            }
            state.counts[path] = counts
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(size - start)\r\n\(extra)"
            + "Accept-Ranges: bytes\r\nETag: \"\(path)-v1\"\r\nContent-Type: application/octet-stream\r\n"
            + "Connection: close\r\n\r\n"
        guard write(client, head) else { return }
        guard request.method != "HEAD" else { return }
        try? handle.seek(toOffset: UInt64(start))
        stream(handle, bytes: size - start, to: client, path: path)
    }

    /// The body, in 64 KB chunks — counted, held or dropped as the test
    /// asked.
    private func stream(_ handle: FileHandle, bytes total: Int, to client: Int32, path: String) {
        var sent = 0
        while sent < total {
            guard let bytes = try? handle.read(upToCount: min(65_536, total - sent)), !bytes.isEmpty else { return }
            guard write(client, bytes) else { return }
            sent += bytes.count
            state.withLock { $0.counts[path, default: Counts()].bytesSent += bytes.count }
            if let dropAt = state.withLock({ $0.drops[path] }), sent >= dropAt {
                state.withLock { $0.drops[path] = nil }
                // A plain close mid-body: the reader sees the connection
                // end short of Content-Length, which is what a lost
                // network looks like.
                return
            }
            if let holdAt = state.withLock({ $0.holds[path] }), sent >= holdAt {
                park()
            }
        }
    }

    /// Parks this connection's thread until `release()`; tells anyone
    /// waiting for a parked connection.
    private func park() {
        let semaphore = DispatchSemaphore(value: 0)
        let watchers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.parked.append(semaphore)
            let watchers = state.parkedWatchers
            state.parkedWatchers.removeAll()
            return watchers
        }
        for watcher in watchers { watcher.resume() }
        semaphore.wait()
    }

    private struct Request {
        let method: String
        let target: String
        let range: Int?
    }

    private func readRequest(_ client: Int32) -> Request? {
        var buffer = Data()
        var piece = [UInt8](repeating: 0, count: 4_096)
        while buffer.count < 65_536 {
            let count = read(client, &piece, piece.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: piece[0..<count])
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let text = String(bytes: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            var range: Int?
            for line in lines.dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("range:"), let bytes = lower.range(of: "bytes=") {
                    let spec = lower[bytes.upperBound...]
                    range = Int(spec.split(separator: "-", omittingEmptySubsequences: false).first ?? "")
                }
            }
            return Request(method: String(parts[0]), target: String(parts[1]), range: range)
        }
        return nil
    }

    @discardableResult
    private func write(_ client: Int32, _ text: String) -> Bool {
        write(client, Data(text.utf8))
    }

    /// Writes all of `data`, or reports the peer gone.
    private func write(_ client: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.send(client, raw.baseAddress! + offset, data.count - offset, MSG_NOSIGNAL)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}
