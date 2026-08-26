import Foundation
import Testing

@testable import MultiModalKitBench

/// 4n — AC-169. The cold-compile control must not lie. §30's lesson wears
/// a new coat: a "cleared" claim over an empty directory is an instrument
/// reporting success at measuring nothing. So the report NAMES what it
/// found — paths and bytes — and absence is said in words, never dressed
/// as work done.
@Suite("the compiled-plan cache control does not lie")
struct CompiledPlanCacheTests {

    func makeCaches(named: [String: Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, bytes) in named {
            let dir = root.appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes)
                .write(to: dir.appending(path: "payload.bin"))
        }
        return root
    }

    @Test("the report names every matching directory and its bytes")
    func reportNamesWhatExists() throws {
        let root = try makeCaches(named: [
            "com.apple.e5rt.e5bundlecachenewest": 4096,
            "com.apple.CoreML.something": 1024,
            "unrelated.cache": 512,
        ])
        let cache = CompiledPlanCache(cachesDirectory: root)
        let found = cache.survey()
        #expect(found.count == 2, "the unrelated directory is not ours to touch")
        #expect(found.contains { $0.name == "com.apple.e5rt.e5bundlecachenewest" && $0.bytes == 4096 })
        #expect(found.contains { $0.name.hasPrefix("com.apple.CoreML") && $0.bytes == 1024 })
    }

    @Test("clear deletes ONLY the matching directories and reports each")
    func clearDeletesAndReports() throws {
        // TWO matching directories, because the review ran the mutation:
        // with one seeded, a clear() that quietly stopped after the first
        // deletion stayed green across all 385 tests — and a phone holding
        // both e5rt and mlcompiler caches got a half-warm "cold" probe.
        let root = try makeCaches(named: [
            "com.apple.e5rt.e5bundlecachenewest": 2048,
            "com.apple.mlcompiler.cache": 1024,
            "unrelated.cache": 512,
        ])
        let cache = CompiledPlanCache(cachesDirectory: root)
        let report = cache.clear()
        #expect(report.deleted.count == 2)
        #expect(report.failed.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "com.apple.mlcompiler.cache").path()))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "com.apple.e5rt.e5bundlecachenewest").path()))
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "unrelated.cache").path()),
            "an instrument that deletes beyond its writ is a hazard, not a tool")
        #expect(report.summary.contains("3072"),
                "the bytes of BOTH deleted caches, or the report under-counts")
    }

    @Test("absence is said in words, not dressed as work done")
    func absentCacheSaysSo() throws {
        let root = try makeCaches(named: ["unrelated.cache": 64])
        let report = CompiledPlanCache(cachesDirectory: root).clear()
        #expect(report.deleted.isEmpty)
        #expect(report.summary.contains("no compiled-plan cache"),
                "the §30 fault in a new coat: 'cleared' over nothing")
        // And absence NAMES the neighbourhood, so a wrong prefix list can
        // be extended from the field report instead of guessed at.
        #expect(report.summary.contains("unrelated.cache"))
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
