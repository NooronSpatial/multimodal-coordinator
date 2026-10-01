// THE STALE RESUME (§222; D-129 F-24 A, D-130) — a 5a bug that 5c's 20×
// loop found (run 13): the system's partial file was gone, the resume
// failed, and the stale resume data stayed, so every later attempt would
// have failed the same way until the model was deleted.
//
//     stop mid-file ──▶ resume data kept ──▶ the partial is lost ──▶ the resume fails
//                                                                      │
//        no fresh resume data (stale) ─▶ drop it, download that file from the start, ONCE
//        fresh resume data            ─▶ keep it, fail as today (the next attempt resumes)
//
// The partial is removed ON PURPOSE here: the resume data names it, and a
// test that cannot find it fails loudly instead of skipping — Apple does
// not document that format, and a silent skip would be a proof of nothing.

import Foundation
import Testing
@testable import MultiModalKit

@Suite("AC-331…AC-333 · a stale resume restarts its file once", .timeLimit(.minutes(1)), .serialized)
struct ModelDownloaderStaleResumeTests {

    struct PartialNotFound: Error, CustomStringConvertible {
        let description: String
    }

    /// Removes the partial file the resume data points at — what the
    /// system did in run 13. Throws, naming what it found, when the
    /// undocumented format does not say where the partial is.
    static func losePartial(_ name: String, in bench: DownloadBench) throws {
        let resume = bench.root.appending(path: "landed/\(name).resume")
        let data = try Data(contentsOf: resume)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        // A keyed archive: every string it holds is in `$objects` — the
        // partial's path among them, or its bare file name.
        let strings = ((plist as? [String: Any])?["$objects"] as? [Any] ?? []).compactMap { $0 as? String }
        // A background session's partial lives in the download DAEMON's
        // folder, one per process (`…/nsurlsessiond/Downloads/<process>/`);
        // a foreground session's, in this process's temporary directory.
        let daemon = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.apple.nsurlsessiond/Downloads")
        let folders = [FileManager.default.temporaryDirectory]
            + ((try? FileManager.default.contentsOfDirectory(at: daemon, includingPropertiesForKeys: nil)) ?? [])
        let candidates = strings.flatMap { text -> [String] in
            text.hasPrefix("/") ? [text] : folders.map { $0.appending(path: text).path }
        }
        guard let partial = candidates.first(where: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }) else {
            throw PartialNotFound(description: "no partial found among the archive's strings: \(strings)")
        }
        try FileManager.default.removeItem(atPath: partial)
    }

    // MARK: - AC-331: nothing to resume from — the file restarts once, and lands

    /// MEASURED, and a guard: a partial removed CLEANLY before the resume is
    /// refetched by the system itself — this row passed on the code before
    /// the fix. So run 13's failure (the daemon's own POSIX 2, mid-resume)
    /// was a race inside the daemon, not the everyday case, and the row
    /// stays to say what the platform does.
    @Test("a partial the system lost before the resume: the system refetches it, and the file lands (AC-331, measured)")
    func aLostPartialIsRefetched() async throws {
        let bench = try DownloadBench()
        defer { bench.tearDown() }
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.hold("big.bin", after: 131_072)
        let plan = bench.plan(["big.bin": size])
        let seen = FractionWatcher()

        let first = Task { try await bench.downloader.transfer(plan, progress: seen.record) }
        await bench.server.parkedConnection()
        await seen.firstFraction()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(bench.resumeDataExists("big.bin"), "the stop kept its resume data (5a F-4 A)")

        try Self.losePartial("big.bin", in: bench)
        bench.server.release()
        let second = FractionWatcher()
        try await bench.downloader.transfer(plan, progress: second.record)

        #expect(bench.sizeOnDisk("big.bin") == size, "restarted from the start, and landed whole")
        #expect(!bench.resumeDataExists("big.bin"), "no stale resume data is left behind")
        #expect(second.fractions == second.fractions.sorted(), "the fraction paused, never stepped back (AC-291)")
    }

    /// THE LOCK-OUT, as it really is: resume data nothing can read — a
    /// `.resume` cut short by a kill mid-write, or one an older system
    /// wrote. The resumed task fails with no fresh data; before the fix the
    /// stale file stayed, and every later attempt failed the same way.
    @Test("resume data nothing can read: the file restarts once from the start, and lands (AC-331)")
    func unreadableResumeDataRestartsOnce() async throws {
        let bench = try DownloadBench(configuration: .ephemeral)
        defer { bench.tearDown() }
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.drop("big.bin", after: 131_072)
        let plan = bench.plan(["big.bin": size])

        await #expect(throws: DownloadFailure.self) { try await bench.downloader.transfer(plan) { _ in } }
        try Data("not resume data".utf8).write(to: bench.root.appending(path: "landed/big.bin.resume"))
        let seen = FractionWatcher()
        try await bench.downloader.transfer(plan, progress: seen.record)

        #expect(bench.sizeOnDisk("big.bin") == size, "restarted from the start, and landed whole")
        #expect(!bench.resumeDataExists("big.bin"), "the stale resume data is gone")
        #expect(seen.fractions == seen.fractions.sorted(), "the fraction never stepped back (AC-291)")
    }

    // MARK: - AC-332: once, never a loop

    /// Resume data nothing can resume from — the same trigger as a lost
    /// partial (a resumed task fails with no fresh data), made on a
    /// FOREGROUND session: a background one retries a dropped connection on
    /// its own for days, so the restart's own failure is reachable only
    /// here (5a's precedent) — and a foreground session was measured to
    /// refetch a merely MISSING partial by itself, so the data is spoiled
    /// instead of its file removed.
    @Test("a restart that fails too ends the transfer — no third attempt (AC-332)")
    func aRestartThatFailsEndsIt() async throws {
        let bench = try DownloadBench(configuration: .ephemeral)
        defer { bench.tearDown() }
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.drop("big.bin", after: 131_072)
        let plan = bench.plan(["big.bin": size])

        await #expect(throws: DownloadFailure.self) { try await bench.downloader.transfer(plan) { _ in } }
        #expect(bench.resumeDataExists("big.bin"), "the dropped transfer kept its resume data")
        try Data("not resume data".utf8).write(to: bench.root.appending(path: "landed/big.bin.resume"))
        bench.server.drop("big.bin", after: 131_072)   // one-shot: this one cuts the RESTART

        await #expect(throws: DownloadFailure.self) { try await bench.downloader.transfer(plan) { _ in } }
        let counts = bench.server.counts(for: "big.bin")
        let story = bench.server.story(for: "big.bin")
        #expect(counts.requests - counts.rangeRequests == 2,
                "the first attempt and ONE restart from the start — never a third: \(counts) — \(story)")
    }

    // MARK: - AC-333: fresh resume data is not stale

    @Test("a resumed task that fails with fresh resume data keeps it, and fails as today (AC-333)")
    func freshResumeDataIsKept() async throws {
        let bench = try DownloadBench(configuration: .ephemeral)
        defer { bench.tearDown() }
        let size = 1_048_576
        try bench.serve("big.bin", bytes: size)
        bench.server.drop("big.bin", after: 131_072)
        let plan = bench.plan(["big.bin": size])

        await #expect(throws: DownloadFailure.self) { try await bench.downloader.transfer(plan) { _ in } }
        // The partial is NOT lost: the next attempt resumes, and is dropped
        // again mid-way — a failure that hands back FRESH resume data.
        bench.server.drop("big.bin", after: 131_072)   // one-shot: this one cuts the RESUME
        await #expect(throws: DownloadFailure.self) { try await bench.downloader.transfer(plan) { _ in } }

        let counts = bench.server.counts(for: "big.bin")
        let story = bench.server.story(for: "big.bin")
        #expect(counts.rangeRequests >= 1, "the second attempt resumed — \(story)")
        #expect(counts.requests - counts.rangeRequests == 1, "and nothing restarted from the start: \(counts) — \(story)")
        #expect(bench.resumeDataExists("big.bin"), "the fresh resume data is kept for the next attempt")
    }
}
