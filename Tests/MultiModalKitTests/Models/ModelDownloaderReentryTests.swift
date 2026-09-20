import Foundation
import Synchronization
import Testing
@testable import MultiModalKit

/// AC-292 and AC-297 (SPEC §203) — the transfer survives the process, and
/// the re-entry door (5a, D-114 F-1 = A).
///
/// The shape of `docs/evidence/5a/probes/probe3`, as a test. A HELPER
/// PROCESS (`DownloadHelper`, built beside this bundle) plays both lives
/// of an app under one session identifier: the first life enqueues a
/// file on a background session and EXITS mid-transfer, with the server
/// holding the connection; the second life — the same executable, run
/// again — either taps (adopts the daemon's task and finishes it) or is
/// woken (hands over a completion handler). The same executable for both
/// lives is not a convenience: the daemon scopes a session by its client,
/// and a session one program started is not shown to another — measured
/// while writing this suite, when the test process itself could not see
/// the helper's task.
///
/// What is measured lives OUTSIDE the helper: the server counts one
/// request, the file appears on disk complete, and the helper's words
/// are checked against both. Waits are events — a line the helper
/// prints, the server saying it has parked, the process exiting.
///
/// Skipped, with the reason on the trait, when the helper is not beside
/// the test bundle — an Xcode run that did not build it can honestly say
/// nothing about a process it cannot start.
@Suite("AC-292/297 · the app that died, and the one that came back",
       .serialized, .timeLimit(.minutes(1)),
       .enabled(if: DownloadHelperProcess.isAvailable,
                "the DownloadHelper executable is not beside the test bundle"))
struct ModelDownloaderReentryTests {

    /// AC-292: the daemon kept the transfer while no process of ours was
    /// alive; the second life ADOPTS it by its description when the
    /// person taps again, sees a fraction at once, and gets the complete
    /// file without a second request.
    @Test("a tap in the second life adopts the transfer the first life started")
    func aTapInTheSecondLifeAdoptsTheTransfer() async throws {
        let bench = try DownloadBench(configuration: .ephemeral)   // its server and directory only
        defer { bench.tearDown() }
        let identifier = "reentry.\(UUID().uuidString)"
        let size = 4_194_304
        try bench.serve("big.bin", bytes: size)
        bench.server.hold("big.bin", after: 65_536)
        let file = try #require(bench.plan(["big.bin": size]).files.first)

        let firstLife = try DownloadHelperProcess.run("enqueue", identifier: identifier, file: file)
        let firstWords = await firstLife.exited()
        #expect(firstWords.contains("enqueued"), "the first life saw a byte and died: \(firstWords)")
        #expect(bench.server.counts(for: "big.bin").requests == 1, "the first life asked once")
        #expect(bench.sizeOnDisk("big.bin") == nil, "and died before the file landed")

        let secondLife = try DownloadHelperProcess.run("adopt", identifier: identifier, file: file)
        let adopted = await secondLife.line(containing: "adopted")
        #expect(adopted != nil, "the second life reports a fraction before any new byte moved")
        bench.server.release()
        let secondWords = await secondLife.exited()

        #expect(secondWords.contains("landed \(size)"), "the second life finished the file: \(secondWords)")
        #expect(bench.sizeOnDisk("big.bin") == size, "complete, on disk")
        #expect(bench.server.counts(for: "big.bin").requests == 1, "no second request: adopted, not restarted")
    }

    /// AC-297, the half a Mac can see: with nobody tapping, the file still
    /// lands — the delegate moves it into place from the task's own
    /// description — while the second life has handed its completion
    /// handler over. The landing is watched as a file-system EVENT on the
    /// destination directory, armed before the server is released.
    ///
    /// THE OTHER HALF IS THE PHONE'S. The handler rides on
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`, which the
    /// system sends only on iOS (measured here: the helper's `wake` mode
    /// waited 40 s on this Mac and was never called). The library calls
    /// the handler on nothing else — calling it early would let the
    /// system suspend the app before its landings were delivered — so
    /// "the handler is called once" is a row on Ryad's phone (AC-300),
    /// not a row this suite can honestly claim.
    @Test("the file lands without a tap, while the wake-up's completion handler is held")
    func theFileLandsWithoutATap() async throws {
        let bench = try DownloadBench(configuration: .ephemeral)
        defer { bench.tearDown() }
        let identifier = "reentry.\(UUID().uuidString)"
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.hold("big.bin", after: 65_536)
        let file = try #require(bench.plan(["big.bin": size]).files.first)

        let firstLife = try DownloadHelperProcess.run("enqueue", identifier: identifier, file: file)
        let firstWords = await firstLife.exited()
        #expect(firstWords.contains("enqueued"), "the first life saw a byte and died: \(firstWords)")

        let secondLife = try DownloadHelperProcess.run("wake", identifier: identifier, file: file)
        defer { secondLife.terminate() }
        let attached = await secondLife.line(containing: "attached")
        #expect(attached != nil, "the second life handed its completion handler over")
        let landing = try DirectoryWatch(file.destination.deletingLastPathComponent())
        bench.server.release()
        while bench.sizeOnDisk("big.bin") != size { await landing.changed() }

        #expect(bench.sizeOnDisk("big.bin") == size, "landed with nobody asking")
        #expect(bench.server.counts(for: "big.bin").requests == 1)
    }
}

// MARK: - the helper process

enum DownloadHelperProcess {
    /// Beside the test bundle, where SwiftPM puts an executable the test
    /// target depends on. `Bundle(for:)` on a class of THIS target finds
    /// the bundle whichever build system laid it out.
    static var executable: URL? {
        let candidate = Bundle(for: Signal.self).bundleURL.deletingLastPathComponent().appending(path: "DownloadHelper")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var isAvailable: Bool { executable != nil }

    /// Starts one life of the helper and watches what it says.
    static func run(_ mode: String, identifier: String, file: DownloadPlan.File) throws -> HelperRun {
        let executable = try #require(Self.executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = [mode, identifier, file.source.absoluteString, file.destination.path,
                             String(file.expectedBytes ?? 0)]
        return try HelperRun(process)
    }
}

/// A running helper: its lines as they arrive, and its exit — events.
final class HelperRun: @unchecked Sendable {
    private struct State {
        var lines: [String] = []
        var partial = ""
        var exited = false
        var waiting: [(needle: String?, continuation: CheckedContinuation<String?, Never>)] = []
    }

    private let process: Process
    private let pipe = Pipe()
    private let state = Mutex(State())

    init(_ process: Process) throws {
        self.process = process
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self.accept(String(bytes: data, encoding: .utf8) ?? "")
        }
        process.terminationHandler = { [self] _ in
            // Whatever is still in the pipe, then the end.
            self.pipe.fileHandleForReading.readabilityHandler = nil
            let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
            self.accept((String(bytes: rest, encoding: .utf8) ?? "") + "\n")
            self.settle { $0.exited = true }
        }
        try process.run()
    }

    private func accept(_ text: String) {
        settle { state in
            state.partial += text
            while let newline = state.partial.firstIndex(of: "\n") {
                state.lines.append(String(state.partial[..<newline]))
                state.partial = String(state.partial[state.partial.index(after: newline)...])
            }
        }
    }

    /// Applies a change, then answers every waiter the change satisfies —
    /// outside the lock.
    private func settle(_ change: (inout State) -> Void) {
        let answered = state.withLock { state -> [(CheckedContinuation<String?, Never>, String?)] in
            change(&state)
            var answered: [(CheckedContinuation<String?, Never>, String?)] = []
            state.waiting.removeAll { waiter in
                if let needle = waiter.needle {
                    if let line = state.lines.first(where: { $0.contains(needle) }) {
                        answered.append((waiter.continuation, line))
                        return true
                    }
                    if state.exited { answered.append((waiter.continuation, nil)); return true }
                    return false
                }
                guard state.exited else { return false }
                answered.append((waiter.continuation, state.lines.joined(separator: "\n")))
                return true
            }
            return answered
        }
        for (continuation, answer) in answered { continuation.resume(returning: answer) }
    }

    /// The first line containing `needle`, or `nil` once the process has
    /// exited without saying it.
    func line(containing needle: String) async -> String? {
        await withCheckedContinuation { continuation in
            settle { $0.waiting.append((needle, continuation)) }
        }
    }

    /// Every line, once the process has exited.
    func exited() async -> String {
        await withCheckedContinuation { continuation in
            settle { $0.waiting.append((nil, continuation)) }
        } ?? ""
    }

    /// Ends a life the test is done with.
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// A directory's changes, as events: `changed()` returns when something
/// in the directory was written since the last return (or since the
/// watch was armed). Armed BEFORE the change can happen, so a landing
/// cannot slip between the arming and the wait.
final class DirectoryWatch: @unchecked Sendable {
    private let descriptor: Int32
    private let source: any DispatchSourceFileSystemObject
    private let state = Mutex<(pending: Int, waiting: [CheckedContinuation<Void, Never>])>((0, []))

    init(_ directory: URL) throws {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw DownloadBench.Failure.cannotWatch(directory.path) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend],
                                                           queue: DispatchQueue(label: "directory-watch"))
        source.setEventHandler { [self] in
            let waiting = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                let waiting = state.waiting
                state.waiting.removeAll()
                if waiting.isEmpty { state.pending += 1 }
                return waiting
            }
            for continuation in waiting { continuation.resume() }
        }
        source.resume()
    }

    deinit {
        source.cancel()
        close(descriptor)
    }

    func changed() async {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state -> Bool in
                if state.pending > 0 { state.pending -= 1; return true }
                state.waiting.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }
}

/// One-shot event: `fire()` once, `wait()` from anywhere, in any order.
/// The wait honours cancellation, so a suite's time limit can end it.
final class Signal: Sendable {
    private let state = Mutex<(fired: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            let waiting = state.waiting
            state.waiting.removeAll()
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let fired = state.withLock { state -> Bool in
                    if !state.fired { state.waiting.append(continuation) }
                    return state.fired
                }
                if fired { continuation.resume() }
            }
        } onCancel: {
            fire()
        }
    }
}
