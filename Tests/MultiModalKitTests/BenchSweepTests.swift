import Foundation
import Synchronization
import Testing

@testable import MultiModalKitBench

/// The sweep's invariants, proved against a stage that cannot lie about
/// what it was asked to do.
///
/// Every one of these tests exists because of a hazard already present in
/// the demo app (SPEC §104): counters that survive between runs, a restart
/// that never says "up", settings that persist the instant they change. The
/// sweep is the place those become defined behaviour instead of accidents.
@Suite("the bench sweep")
struct BenchSweepTests {

    /// A stage that records everything, and can be told to fail.
    ///
    /// `Mutex`, not an actor: the recorder must be readable from the test
    /// body without an await, and it holds nothing across a suspension.
    final class Recorder: BenchStage, Sendable {
        struct Settings: Sendable, Equatable { let token: Int }

        struct Log: Sendable {
            var calls: [String] = []
            var restored: [Int] = []
            var prepared: [String] = []
            var thermalSeries: [String] = []
        }

        let log = Mutex(Log())
        let refusal: String?
        let failOnMeasure: Int?
        /// Cancels the sweep from INSIDE its own task, after row N has been
        /// measured. The old cancellation test called `task.cancel()` from
        /// the test thread immediately after spawning, and whether ANY row
        /// got measured first was scheduling luck — the review reproduced
        /// both outcomes. A lever here makes the moment a fact.
        let cancelAfterMeasure: Int?
        let scriptedConditions: [BenchConditions]

        init(refusal: String? = nil,
             failOnMeasure: Int? = nil,
             cancelAfterMeasure: Int? = nil,
             conditions: [BenchConditions] = []) {
            self.refusal = refusal
            self.failOnMeasure = failOnMeasure
            self.cancelAfterMeasure = cancelAfterMeasure
            self.scriptedConditions = conditions
        }

        struct Boom: Error {}

        private func note(_ what: String) {
            log.withLock { $0.calls.append(what) }
        }

        func snapshot() async -> Settings {
            note("snapshot")
            return Settings(token: 7)
        }

        func restore(_ settings: Settings) async {
            log.withLock {
                $0.calls.append("restore")
                $0.restored.append(settings.token)
            }
        }

        func refusalReason() async -> String? {
            note("refusalReason")
            return refusal
        }

        func prepare(_ configuration: BenchConfiguration) async throws {
            log.withLock {
                $0.calls.append("prepare")
                $0.prepared.append(configuration.name)
            }
        }

        func resetCounters() async { note("reset") }

        func conditions() async -> BenchConditions {
            let index = log.withLock { $0.calls.filter { $0 == "conditions" }.count }
            note("conditions")
            if index < scriptedConditions.count { return scriptedConditions[index] }
            return BenchConditions(thermal: "nominal", freeMegabytes: 934)
        }

        func measure() async throws -> BenchTiming {
            let index = log.withLock { $0.calls.filter { $0 == "measure" }.count }
            note("measure")
            if let failOnMeasure, index == failOnMeasure { throw Boom() }
            if let cancelAfterMeasure, index == cancelAfterMeasure {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return BenchTiming(firstAudio: .milliseconds(177),
                               total: .milliseconds(6578))
        }
    }

    static let one = [BenchConfiguration(name: "stepped + latency",
                                         decoder: .stepped, vocoder: .latency)]

    // MARK: AC-146 — the sweep refuses rather than dies

    @Test("with the mind resident it refuses, and changes nothing")
    func refusesWithMindResident() async throws {
        let stage = Recorder(refusal: "the mind is resident")
        await #expect(throws: BenchSweep.Refusal.refused("the mind is resident")) {
            try await BenchSweep.run(Self.one, runsEach: 1, on: stage)
        }
        let calls = stage.log.withLock { $0.calls }
        #expect(!calls.contains("prepare"), "it must not touch the device it refused")
        #expect(!calls.contains("snapshot"), "nothing to restore if nothing was taken")
    }

    // MARK: AC-147 / AC-149 — the order, per row

    @Test("each row is prepare → reset → sample → measure, in that order")
    func theOrderHolds() async throws {
        let stage = Recorder()
        _ = try await BenchSweep.run(Self.one, runsEach: 2, on: stage)
        let calls = stage.log.withLock { $0.calls }
        #expect(calls == ["refusalReason", "snapshot",
                          "prepare", "reset", "conditions", "measure",
                          "prepare", "reset", "conditions", "measure",
                          "restore"])
    }

    @Test("reset happens AFTER prepare — the row counts the run, not the setup")
    func resetFollowsPrepare() async throws {
        let stage = Recorder()
        _ = try await BenchSweep.run(Self.one, runsEach: 1, on: stage)
        let calls = stage.log.withLock { $0.calls }
        let prepare = try #require(calls.firstIndex(of: "prepare"))
        let reset = try #require(calls.firstIndex(of: "reset"))
        let measure = try #require(calls.firstIndex(of: "measure"))
        #expect(prepare < reset && reset < measure)
    }

    @Test("every configuration is prepared before it is measured, every run")
    func everyRunPrepares() async throws {
        let stage = Recorder()
        let rows = try await BenchSweep.run(BenchConfiguration.phone,
                                            runsEach: 3, on: stage)
        #expect(rows.count == 12)
        let prepared = stage.log.withLock { $0.prepared }
        #expect(prepared.count == 12, "a reused configuration is not a prepared one")
    }

    // MARK: AC-148 — each row carries ITS OWN conditions

    @Test("a row carries the conditions sampled for that row, not the sweep's first")
    func conditionsArePerRow() async throws {
        let stage = Recorder(conditions: [
            BenchConditions(thermal: "nominal", freeMegabytes: 934),
            BenchConditions(thermal: "fair", freeMegabytes: 900),
            BenchConditions(thermal: "serious", freeMegabytes: 880)
        ])
        let rows = try await BenchSweep.run(Self.one, runsEach: 3, on: stage)
        #expect(rows.map(\.conditions.thermal) == ["nominal", "fair", "serious"])
        #expect(rows.map(\.conditions.freeMegabytes) == [934, 900, 880])
    }

    // MARK: AC-151 — death leaves no residue

    @Test("a stage that throws mid-sweep still gets its settings back")
    func restoresOnFailure() async throws {
        // failOnMeasure: 0 — nothing was measured, so there is nothing to
        // carry out and the stage's own error reaches the caller unwrapped.
        // The "some rows measured" path is `throwCarriesTheRowsOut`.
        let stage = Recorder(failOnMeasure: 0)
        await #expect(throws: Recorder.Boom.self) {
            try await BenchSweep.run(Self.one, runsEach: 3, on: stage)
        }
        let log = stage.log.withLock { $0 }
        #expect(log.restored == [7], "restored exactly once, with what was taken")
        #expect(log.calls.last == "restore", "and restored LAST, after the failure")
    }

    @Test("a completed sweep restores exactly once")
    func restoresOnSuccess() async throws {
        let stage = Recorder()
        _ = try await BenchSweep.run(Self.one, runsEach: 2, on: stage)
        #expect(stage.log.withLock { $0.restored } == [7])
    }

    @Test("cancellation keeps the rows already measured, and still restores")
    func cancellationRestores() async throws {
        // Cancelled from INSIDE, after the second row is measured — so
        // "some rows exist, and the sweep stopped" is a fact rather than a
        // scheduling coincidence. The previous version cancelled from the
        // test thread right after spawning and could observe zero rows.
        let stage = Recorder(cancelAfterMeasure: 1)
        let rows = try await BenchSweep.run(BenchConfiguration.phone,
                                            runsEach: 3, on: stage)
        // ONE, not two: row 0 completed, and row 1 — the one being measured
        // when the cancel landed — is dropped rather than published.
        #expect(rows.count == 1, "the row measured before the cancel")
        #expect(rows.count < 12, "and the sweep did not complete")
        #expect(stage.log.withLock { $0.restored } == [7])
    }

    @Test("the row being measured when the cancel lands is DROPPED, not published")
    func cancelledRowIsNotPublished() async throws {
        // The cancel arrives during row index 0's measure, so that row's
        // timing exists but describes a truncated utterance. Publishing it
        // would put a fast-looking row in the table for a reply that was
        // interrupted.
        let stage = Recorder(cancelAfterMeasure: 0)
        let rows = try await BenchSweep.run(Self.one, runsEach: 3, on: stage)
        #expect(rows.isEmpty, "a truncated measurement is not a measurement")
        #expect(stage.log.withLock { $0.restored } == [7])
    }

    @Test("a throw part-way keeps every row already measured")
    func throwCarriesTheRowsOut() async throws {
        // Nine good rows used to die with the tenth: `run` held them in a
        // local array and the throw path dropped it.
        let stage = Recorder(failOnMeasure: 2)
        do {
            _ = try await BenchSweep.run(Self.one, runsEach: 3, on: stage)
            Issue.record("it should have thrown")
        } catch let interrupted as BenchSweep.Interrupted {
            #expect(interrupted.rows.count == 2,
                    "the two rows measured before the failure survive")
        }
        #expect(stage.log.withLock { $0.restored } == [7])
    }

    @Test("runsEach of zero measures nothing — it does not halt the process")
    func zeroRunsIsEmptyNotFatal() async throws {
        let stage = Recorder()
        let rows = try await BenchSweep.run(Self.one, runsEach: 0, on: stage)
        #expect(rows.isEmpty)
        // And the settings still come back: a sweep that measured nothing
        // is still a sweep that borrowed them.
        #expect(stage.log.withLock { $0.restored } == [7])
    }

    // MARK: AC-150 — the numbers leave as markdown

    @Test("the table is the shape INSTRUMENTS already uses")
    func markdownShape() {
        let rows = [
            BenchRow(configuration: Self.one[0], run: 1,
                     timing: .init(firstAudio: .milliseconds(177),
                                   total: .milliseconds(6578)),
                     conditions: .init(thermal: "nominal", freeMegabytes: 934))
        ]
        #expect(BenchTable.markdown(rows) == """
        | config | run | first audio | total | thermal | free |
        |---|---|---|---|---|---|
        | stepped + latency | 1 | 177 ms | 6578 ms | nominal | 934 MB |

        """)
    }

    @Test("a reply that never spoke prints an em dash, never 0 ms")
    func silentRowIsNotTheFastestRow() {
        let rows = [
            BenchRow(configuration: Self.one[0], run: 1,
                     timing: .init(firstAudio: nil, total: .milliseconds(903)),
                     conditions: .init(thermal: "nominal", freeMegabytes: 934))
        ]
        let table = BenchTable.markdown(rows)
        #expect(table.contains("| — | 903 ms |"))
        // `903 ms` contains `0 ms`, so the naive check passed for the wrong
        // reason — assert on the CELL, not on a substring of the row.
        #expect(!table.contains("| 0 ms |"),
                "zero is the BEST value in a first-audio column")
    }

    @Test("a device that cannot answer prints an em dash, never 0 MB")
    func unknownHeadroomIsNotZero() {
        let rows = [
            BenchRow(configuration: Self.one[0], run: 1,
                     timing: .init(firstAudio: .milliseconds(1),
                                   total: .milliseconds(2)),
                     conditions: .init(thermal: "nominal", freeMegabytes: nil))
        ]
        let table = BenchTable.markdown(rows)
        #expect(table.contains("| — |"))
        #expect(!table.contains("0 MB"), "0 MB is what an unanswerable API returns")
    }

    @Test("durations render as whole milliseconds")
    func millisecondRendering() {
        #expect(BenchTable.milliseconds(.milliseconds(177)) == 177)
        #expect(BenchTable.milliseconds(.seconds(6) + .milliseconds(578)) == 6578)
        #expect(BenchTable.milliseconds(.zero) == 0)
    }

    // MARK: the phone list

    @Test("the phone sweep does not include a decoder that cannot load there")
    func phoneListExcludesFused() {
        #expect(BenchConfiguration.phone.allSatisfy { $0.decoder == .stepped })
        #expect(BenchConfiguration.mac.contains { $0.decoder == .fused },
                "the Mac list must still cover it, or §31 is unreproducible")
    }
}
