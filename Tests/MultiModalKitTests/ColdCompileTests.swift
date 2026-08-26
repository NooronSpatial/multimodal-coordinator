import Foundation
import Testing

@testable import MultiModalKitBench

/// 4n — AC-169. The cold-compile control must not lie. §30's lesson wears
/// a new coat: a "cleared" claim over an empty directory is an instrument
/// reporting success at measuring nothing. So the report NAMES what it
/// found — paths and bytes — and absence is said in words, never dressed
/// as work done.
///
/// D-075 widened the writ: the survey now walks a LIST of directories
/// (the app passes Caches and tmp), an entry says WHERE it was found,
/// and absence names EVERY neighbourhood — because "tmp/ holds nothing"
/// is the exact line that closes AC-172 as system-owned.
@Suite("the compiled-plan cache control does not lie")
struct CompiledPlanCacheTests {

    /// Builds a fake app container: each key is a surveyed directory
    /// ("Caches", "tmp"), each value the cache directories inside it and
    /// their payload bytes. Callers MUST `defer` removal of the returned
    /// root — the first version of this helper never cleaned up, and the
    /// D-075 session found ten leaked `cold-*` fixtures sitting in the
    /// real $TMPDIR: the very directory class this control now surveys.
    func makeContainer(_ layout: [String: [String: Int]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cold-\(UUID().uuidString)")
        for (directory, contents) in layout {
            let dir = root.appending(path: directory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, bytes) in contents {
                let sub = dir.appending(path: name)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                try Data(repeating: 7, count: bytes)
                    .write(to: sub.appending(path: "payload.bin"))
            }
        }
        return root
    }

    @Test("the report names every matching directory and its bytes")
    func reportNamesWhatExists() throws {
        let root = try makeContainer(["Caches": [
            "com.apple.e5rt.e5bundlecachenewest": 4096,
            "com.apple.CoreML.something": 1024,
            "unrelated.cache": 512,
        ]])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompiledPlanCache(directories: [root.appending(path: "Caches")])
        let found = cache.survey()
        #expect(found.count == 2, "the unrelated directory is not ours to touch")
        #expect(found.contains { $0.name == "com.apple.e5rt.e5bundlecachenewest" && $0.bytes == 4096 })
        #expect(found.contains { $0.name.hasPrefix("com.apple.CoreML") && $0.bytes == 1024 })
    }

    @Test("the survey reaches every directory, and an entry says where it was found")
    func surveyReachesEveryDirectory() throws {
        // D-075's whole point: a cache hiding in tmp/ while Caches holds
        // none. A survey that stops at its first directory stays green on
        // every older test and misses exactly this.
        let root = try makeContainer([
            "Caches": ["unrelated.cache": 512],
            "tmp": ["com.apple.e5rt.e5bundlecachenewest": 2048],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompiledPlanCache(directories: [
            root.appending(path: "Caches"), root.appending(path: "tmp"),
        ])
        let found = cache.survey()
        #expect(found.count == 1)
        #expect(found.first?.location == "tmp",
                "the report must say WHERE, or the field cannot tell Caches from tmp")
        #expect(found.first?.bytes == 2048)
    }

    @Test("clear deletes from EVERY directory and reports each with its place")
    func clearDeletesAndReports() throws {
        // TWO matching directories in TWO surveyed places, because the 4n
        // review ran the mutation: with one seeded, a clear() that quietly
        // stopped after the first deletion stayed green — and D-075 adds
        // the sibling fault, a clear() that stops after the first
        // DIRECTORY. Both must fail here.
        let root = try makeContainer([
            "Caches": ["com.apple.e5rt.e5bundlecachenewest": 2048],
            "tmp": ["com.apple.mlcompiler.cache": 1024, "unrelated.cache": 512],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CompiledPlanCache(directories: [
            root.appending(path: "Caches"), root.appending(path: "tmp"),
        ])
        let report = cache.clear()
        #expect(report.deleted.count == 2)
        #expect(report.failed.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "Caches/com.apple.e5rt.e5bundlecachenewest").path()))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "tmp/com.apple.mlcompiler.cache").path()))
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "tmp/unrelated.cache").path()),
            "an instrument that deletes beyond its writ is a hazard, not a tool")
        #expect(report.summary.contains("3072"),
                "the bytes of BOTH deleted caches, or the report under-counts")
        #expect(report.summary.contains("Caches/com.apple.e5rt.e5bundlecachenewest"))
        #expect(report.summary.contains("tmp/com.apple.mlcompiler.cache"))
    }

    @Test("absence is said in words, and it names EVERY neighbourhood")
    func absentCacheSaysSo() throws {
        let root = try makeContainer([
            "Caches": ["unrelated.cache": 64],
            "tmp": ["leftover.tmp": 32],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = CompiledPlanCache(directories: [
            root.appending(path: "Caches"), root.appending(path: "tmp"),
        ]).clear()
        #expect(report.deleted.isEmpty)
        #expect(report.summary.contains("no compiled-plan cache"),
                "the §30 fault in a new coat: 'cleared' over nothing")
        // Absence NAMES each neighbourhood separately — "tmp holds:
        // [nothing but leftovers]" is the exact evidence AC-172's
        // fall-through to C rests on (D-075).
        #expect(report.summary.contains("Caches holds: [unrelated.cache]"))
        #expect(report.summary.contains("tmp holds: [leftover.tmp]"))
    }

    @Test("a directory the control cannot read is reported as such, not as empty")
    func unreadableDirectoryIsNotNothing() throws {
        // "holds: [nothing]" over a directory that was never opened would
        // be the instrument fault again, one layer down.
        let root = try makeContainer(["Caches": ["unrelated.cache": 64]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = CompiledPlanCache(directories: [
            root.appending(path: "Caches"), root.appending(path: "never-created"),
        ]).clear()
        #expect(report.summary.contains("never-created is unreadable or absent"))
    }
}

/// 4n — AC-170. The null-run rule as a pure, testable sentence: a probe
/// phase that produced ZERO sampler lines watched a load that never
/// happened, and the trace must say so instead of blessing it.
@Suite("a null probe phase is announced")
struct NullPhaseTests {

    @Test("zero samples means the phase measured nothing, and the line says why")
    func zeroSamplesAnnounced() throws {
        // `throws` + `try`, not `try!` — the review reproduced the trap: a
        // regression here would kill the whole test process with signal 5
        // instead of failing one test red, taking every later suite down.
        let line = PressurePhaseVerdict.nullRunLine(samples: 0, label: "voice")
        let announced = try #require(line)
        #expect(announced.contains("ALREADY"))
        #expect(announced.contains("measured nothing"))
    }

    @Test("a phase with real samples gets no announcement — one sample included")
    func realPhaseSilent() {
        #expect(PressurePhaseVerdict.nullRunLine(samples: 12, label: "voice") == nil)
        // The boundary, pinned: ONE sample is a fast real load, not a null
        // run — a `samples <= 1` mutation must fail here.
        #expect(PressurePhaseVerdict.nullRunLine(samples: 1, label: "voice") == nil)
    }
}
