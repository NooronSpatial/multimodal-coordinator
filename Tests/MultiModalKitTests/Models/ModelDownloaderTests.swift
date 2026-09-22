import Foundation
import Synchronization
import Testing
@testable import MultiModalKit

/// AC-291, AC-293, AC-296 (SPEC §203) — the downloader, measured against
/// a loopback server that counts (5a, D-114 F-1 = A, F-4 = A, F-8 = A).
///
/// Every row moves REAL bytes through a REAL `URLSession` on a background
/// configuration — the mechanism the milestone exists for — into a
/// temporary directory. The server counts requests and bytes, so the
/// promises are numbers: one request per file for a join, a `206` at the
/// right offset for a resume, never twice the file.
///
/// Waits are events: the server says when a connection has parked, the
/// progress closure says when a fraction arrived, the transfer says when
/// it is done. No sleeps, no polls.
@Suite("AC-291/293/296 · the downloader against a counting server", .serialized, .timeLimit(.minutes(1)))
struct ModelDownloaderTests {

    // MARK: AC-291 — the fractions

    @Test("fractions never decrease and end at exactly one 1.0; every file lands complete")
    func fractionsNeverDecreaseAndEndAtOne() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        try bench.serve("a.bin", bytes: 300_000)
        try bench.serve("b.bin", bytes: 200_000)
        try bench.serve("c.bin", bytes: 100_000)
        let plan = bench.plan(["a.bin": 300_000, "b.bin": 200_000, "c.bin": 100_000])
        let seen = FractionWatcher()

        try await bench.downloader.transfer(plan, progress: seen.record)

        let fractions = seen.fractions
        #expect(!fractions.isEmpty, "a 600 KB transfer reports progress")
        #expect(fractions == fractions.sorted(), "never decreasing: \(fractions)")
        #expect(fractions.last == 1.0, "the last word is 1.0")
        #expect(fractions.filter { $0 == 1.0 }.count == 1, "and it is said once")
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        for (name, bytes) in ["a.bin": 300_000, "b.bin": 200_000, "c.bin": 100_000] {
            #expect(bench.sizeOnDisk(name) == bytes, "\(name) landed complete")
            #expect(bench.server.counts(for: name).requests == 1, "\(name) was asked for once")
        }
    }

    @Test("a plan whose files are already complete reports one 1.0 and asks the server nothing")
    func anInstalledPlanReportsOneOneAndAsksNothing() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        try bench.serve("a.bin", bytes: 4_096)
        try bench.place("a.bin", bytes: 4_096)
        let seen = FractionWatcher()

        try await bench.downloader.transfer(bench.plan(["a.bin": 4_096]), progress: seen.record)

        #expect(seen.fractions == [1.0], "one true word, nothing invented before it")
        #expect(bench.server.counts(for: "a.bin").requests == 0, "asking is free")
    }

    @Test("a file that lands short of its declared size is refused and not kept")
    func aShortFileIsRefused() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        try bench.serve("a.bin", bytes: 100_000)

        await #expect(throws: DownloadFailure.shortFile(file: "a.bin", got: 100_000, expected: 200_000)) {
            try await bench.downloader.transfer(bench.plan(["a.bin": 200_000])) { _ in }
        }
        #expect(bench.sizeOnDisk("a.bin") == nil, "a short file is not left pretending")
    }

    // MARK: AC-293 — resume, measured in bytes

    @Test("a cancel keeps resume data; the next transfer sends Range, gets 206, and never pays twice")
    func aCancelKeepsResumeDataAndTheNextTransferResumes() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let size = 2_097_152
        try bench.serve("big.bin", bytes: size)
        bench.server.hold("big.bin", after: 262_144)
        let plan = bench.plan(["big.bin": size])
        let seen = FractionWatcher()

        let first = Task { try await bench.downloader.transfer(plan, progress: seen.record) }
        await bench.server.parkedConnection()
        await seen.firstFraction()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        #expect(bench.resumeDataExists("big.bin"), "the resume data waits beside the destination")
        #expect(bench.sizeOnDisk("big.bin") == nil, "and the destination is not there yet")
        let paidBefore = bench.server.counts(for: "big.bin").bytesSent
        #expect(paidBefore >= 262_144 && paidBefore < size, "the first attempt was cut mid-file")

        bench.server.release()
        try await bench.downloader.transfer(plan) { _ in }

        let counts = bench.server.counts(for: "big.bin")
        #expect(counts.rangeRequests == 1, "the second attempt asked for a Range")
        #expect((counts.firstRangeOffset ?? 0) > 0, "from where the first one stopped")
        #expect(counts.bytesSent < 2 * size, "never twice the file: \(counts.bytesSent) of \(size)")
        #expect(bench.sizeOnDisk("big.bin") == size, "complete")
        #expect(!bench.resumeDataExists("big.bin"), "the resume data is spent")
    }

    @Test("a dropped connection keeps resume data too (F-4 A), on a foreground session")
    func aFailedTransferKeepsResumeData() async throws {
        // A background session RETRIES a lost connection on its own, for
        // days; the failure path is reachable in a test only on a
        // foreground configuration, whose delegate code is the same.
        let bench = try DownloadBench(configuration: .ephemeral)
        defer { bench.tearDown() }
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.drop("big.bin", after: 262_144)

        // do/catch, not `Result { try await … }`: the async `Result` init is
        // Swift 6.4's, and CI's toolchain is 6.3 — pushed red once, fixed forward.
        var failure: DownloadFailure?
        do {
            try await bench.downloader.transfer(bench.plan(["big.bin": size])) { _ in }
        } catch let error as DownloadFailure {
            failure = error
        }
        guard case .transferFailed(let file, _)? = failure else {
            Issue.record("expected transferFailed, got \(String(describing: failure))")
            return
        }
        #expect(file == "big.bin")
        #expect(bench.resumeDataExists("big.bin"), "what can be resumed is kept")

        try await bench.downloader.transfer(bench.plan(["big.bin": size])) { _ in }
        #expect(bench.server.counts(for: "big.bin").rangeRequests == 1, "resumed, not restarted")
        #expect(bench.sizeOnDisk("big.bin") == size)
    }

    // MARK: AC-296 — a join

    @Test("two callers, one transfer: one request per file, both see the fractions, both return")
    func twoCallersOneTransfer() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        try bench.serve("a.bin", bytes: 524_288)
        bench.server.hold("a.bin", after: 65_536)
        let plan = bench.plan(["a.bin": 524_288])
        let one = FractionWatcher(), two = FractionWatcher()

        let first = Task { try await bench.downloader.transfer(plan, progress: one.record) }
        await bench.server.parkedConnection()
        let second = Task { try await bench.downloader.transfer(plan, progress: two.record) }
        await two.firstFraction()
        bench.server.release()
        try await first.value
        try await second.value

        #expect(bench.server.counts(for: "a.bin").requests == 1, "one transfer")
        #expect(one.fractions.last == 1.0)
        #expect(two.fractions.last == 1.0)
        #expect(bench.sizeOnDisk("a.bin") == 524_288)
    }

    @Test("F-8 A: the transfer stops when the LAST waiter cancels, not the first")
    func theLastWaiterOutStopsTheTransfer() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        try bench.serve("a.bin", bytes: 524_288)
        bench.server.hold("a.bin", after: 65_536)
        let plan = bench.plan(["a.bin": 524_288])
        let two = FractionWatcher()

        let first = Task { try await bench.downloader.transfer(plan) { _ in } }
        await bench.server.parkedConnection()
        let second = Task { try await bench.downloader.transfer(plan, progress: two.record) }
        await two.firstFraction()

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await bench.downloader.isTransferring(plan), "the second waiter keeps it alive")
        #expect(!bench.resumeDataExists("a.bin"), "nothing was cancelled yet")

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await !bench.downloader.isTransferring(plan), "the last one out stops it")
        #expect(bench.resumeDataExists("a.bin"), "and what can be resumed is kept")
        bench.server.release()
    }
}

// MARK: - the bench

/// A server, a scratch directory and a downloader, torn down together.
struct DownloadBench {
    enum Failure: Error { case cannotWatch(String) }

    let root: URL
    let server: LoopbackFileServer
    let downloader: ModelDownloader

    init(configuration: URLSessionConfiguration? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "download-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "served"),
                                                withIntermediateDirectories: true)
        server = try LoopbackFileServer(directory: root.appending(path: "served"))
        let configuration = configuration
            ?? URLSessionConfiguration.background(withIdentifier: "download-bench.\(UUID().uuidString)")
        downloader = ModelDownloader(configuration: configuration)
    }

    func tearDown() {
        server.stop()
        let downloader = downloader
        Task { await downloader.invalidate() }
        try? FileManager.default.removeItem(at: root)
    }

    /// A served file of `bytes` — not zeros, so a short read is a
    /// different file and not a run of the same byte.
    func serve(_ name: String, bytes: Int) throws {
        var data = Data(count: bytes)
        for index in stride(from: 0, to: bytes, by: 4_096) { data[index] = UInt8(truncatingIfNeeded: index / 4_096) }
        try data.write(to: root.appending(path: "served/\(name)"))
    }

    /// A served file with these exact bytes — a listing endpoint's JSON —
    /// at a path that may be nested.
    func serve(_ name: String, text: String) throws {
        let file = root.appending(path: "served/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// A destination already complete — as an installed model's file is.
    func place(_ name: String, bytes: Int) throws {
        let destination = root.appending(path: "landed/\(name)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: destination)
    }

    func plan(_ files: [String: Int]) -> DownloadPlan {
        DownloadPlan(files: files.sorted { $0.key < $1.key }.map { name, bytes in
            DownloadPlan.File(source: server.url(for: name),
                              destination: root.appending(path: "landed/\(name)"),
                              expectedBytes: Int64(bytes))
        })
    }

    func sizeOnDisk(_ name: String) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: root.appending(path: "landed/\(name)").path)[.size] as? Int
    }

    func resumeDataExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "landed/\(name).resume").path)
    }
}

/// Records fractions and says when one arrived — the event a test gates
/// on instead of a delay.
final class FractionWatcher: Sendable {
    private struct State {
        var fractions: [Double] = []
        var waiting: [(atLeast: Double, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())

    var fractions: [Double] { state.withLock { $0.fractions } }

    @Sendable func record(_ fraction: Double) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fractions.append(fraction)
            let best = state.fractions.max() ?? 0
            let woken = state.waiting.filter { $0.atLeast <= best }.map(\.continuation)
            state.waiting.removeAll { $0.atLeast <= best }
            return woken
        }
        for continuation in woken { continuation.resume() }
    }

    /// Any fraction at all.
    func firstFraction() async { await fraction(atLeast: 0) }

    /// A fraction this large or larger — how a test knows the LARGE file
    /// of a plan has bytes on disk, and not only the small ones beside
    /// it: a cancel before the large file's first write produces no
    /// resume data, and a row that cancelled on the small files' fraction
    /// went red under load for exactly that (`docs/evidence/5a`).
    func fraction(atLeast threshold: Double) async {
        await withCheckedContinuation { continuation in
            let arrived = state.withLock { state -> Bool in
                if (state.fractions.max() ?? -1) >= threshold { return true }
                state.waiting.append((threshold, continuation))
                return false
            }
            if arrived { continuation.resume() }
        }
    }
}

/// AC-292's platform footnote (5a, piece 6): where the library's session
/// really runs in the background, and where it cannot.
///
/// The simulator has no background transfer daemon — measured, not
/// assumed: the demo's first run there failed every file at once with
/// `NSURLErrorDomain Code=-1`, the same URL on a background session on a
/// Mac answered `200`, and the same download in the simulator on a
/// foreground session installed and deleted cleanly
/// (`docs/evidence/5a/simulator-2026-09-22-background-session.md`). So
/// the simulator gets a foreground session and loses only what that
/// platform never had; every other platform keeps the background one.
@Suite("AC-292 · the session is background everywhere it can be")
struct ModelDownloadsConfigurationTests {
    @Test("the library's session is a background session — except in the simulator, which has none")
    func theSessionIsBackgroundWhereItCanBe() {
        let configuration = ModelDownloads.backgroundConfiguration(identifier: "test.identifier")
        #if targetEnvironment(simulator)
        #expect(configuration.identifier == nil, "the simulator cannot run one, so it does not pretend to")
        #else
        #expect(configuration.identifier == "test.identifier")
        #expect(configuration.sessionSendsLaunchEvents, "the system may relaunch the app to deliver events")
        #expect(configuration.isDiscretionary == false, "a person asked for these bytes")
        #endif
    }
}
