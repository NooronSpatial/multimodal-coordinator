// THE APPLE MIND'S REAL DEADLINE (4y piece 3, AC-264, D-107 F-4 = A).
//
// `GenerationOptions.deadline` is slept on the mind's INJECTED clock, racing
// the vendor's snapshot stream. When the clock wins, the run cancels its
// stream task and ends `.finished(.deadline)` with the text so far — an
// ending, never a failure. When the stream wins, the sleeper is released
// the moment the terminal is taken, so a `ManualClock` is never left
// holding a dead reply's clock. Both endings go through the run's ONE
// retired latch, so exactly one terminal is ever reported — proved below
// by making the two happen in each order, and then at once.
//
// **Nothing here polls** (§3.3). Every wait is an EVENT — a snapshot
// source that announces when it was opened and when its task was
// cancelled, a witness that announces each update the run emits, and the
// clock's own `waitForSleepers` — each raced against a SLEEPING cap so a
// red test dies in seconds. The clock is a `ManualClock`; no test here
// touches wall time.
//
// **The run is held alive through every assertion** (`withExtendedLifetime`).
// The run's `deinit` also stops the sleeper — a safety net for a dropped
// run — and the first cut of these tests let the witness drop the run at
// "ended", so a mutation that removed the release from `report()` stayed
// GREEN: the net had caught it. Holding the run makes `report()` and
// `cancel()` the only hands that can empty the clock, which is the claim.

import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit

// MARK: - a snapshot source the TEST holds open

/// Yields the cumulative snapshots the test pushes, finishes when the test
/// says, and ANNOUNCES two facts as events: `opened` (the run asked for
/// its stream) and `terminated` (the run's stream task was cancelled or
/// finished — the vendor's `onTermination`, which is where the real
/// source cancels its session task). A source that never finishes on its
/// own is exactly the slow reply AC-264 is about.
final class HeldSnapshotSource: ReplySnapshotStreaming, @unchecked Sendable {
    private let hand = Mutex<AsyncThrowingStream<String, any Error>.Continuation?>(nil)
    private let cancelled = Mutex(false)
    let signals = RunSignals()

    var unavailable: MindUnavailable? { nil }

    /// True once the run CANCELLED its stream task — the vendor's
    /// `onTermination(.cancelled)`, where the real source cancels the
    /// session task. A stream the vendor finished on its own never sets
    /// it. (`Termination` carries an untyped error and is not `Equatable`,
    /// so the one fact the tests need is read out as a flag.)
    var sawCancellation: Bool { cancelled.withLock { $0 } }

    func snapshots(for context: ReplyContext,
                   instructions: String?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            hand.withLock { $0 = continuation }
            continuation.onTermination = { [self] reason in
                if case .cancelled = reason { self.cancelled.withLock { $0 = true } }
                self.signals.send("terminated")
            }
            signals.send("opened")
        }
    }

    /// The test's hand on the vendor: one more cumulative snapshot.
    func push(_ snapshot: String) { hand.withLock { $0 }?.yield(snapshot) }
    /// The vendor's own ending.
    func finish() { hand.withLock { $0 }?.finish() }
}

// MARK: - a witness on the run's updates

/// Drains a run's updates into a record and ANNOUNCES each one
/// (`update:N`) and the end of the stream (`ended`), so a test waits on
/// the fact that a token reached the run's output before it moves the
/// clock — never on a hope that the worker got there first.
final class Witness: Sendable {
    private let record = Mutex<[ReplyUpdate]>([])
    let signals = RunSignals()
    private let drain = Mutex<Task<Void, Never>?>(nil)

    init(_ run: any ReplyRun) {
        let task = Task { [self] in
            for await update in run.updates {
                let count = self.record.withLock { $0.append(update); return $0.count }
                self.signals.send("update:\(count)")
            }
            self.signals.send("ended")
        }
        drain.withLock { $0 = task }
    }

    var updates: [ReplyUpdate] { record.withLock { $0 } }
    func stop() { drain.withLock { $0 }?.cancel() }
}

/// The event a test waits on, raced against a sleeping cap (the
/// `AdmissionSeamTests` shape).
final class RunSignals: Sendable {
    private let stream: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation

    init() {
        (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    func send(_ name: String) { emit.yield(name) }

    func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await event in stream where event == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - the tests

@Suite("AC-264 · the Apple mind's deadline is the injected clock's ending",
       .timeLimit(.minutes(1)))
struct AppleDeadlineTests {

    /// Waits for the FACT that a sleeper is parked on the clock, raced
    /// against a sleeping cap; the loser is cancelled and
    /// `waitForSleepers` honours it, so nothing is left parked.
    private static func parked(_ clock: ManualClock, atLeast count: Int = 1,
                               within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await clock.waitForSleepers(atLeast: count) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The bench every test below sits at: a fresh `ManualClock`, a held
    /// source, the run opened on them, and a witness on its updates.
    struct Bench {
        let clock: ManualClock
        let source: HeldSnapshotSource
        let run: any ReplyRun
        let witness: Witness
    }

    /// Opens a reply with a 200 ms deadline (unless told otherwise) and
    /// waits for the fact that the run asked the source for its stream.
    @available(macOS 26.0, iOS 26.0, *)
    private static func bench(deadline: Duration? = .milliseconds(200)) async throws -> Bench {
        let clock = ManualClock()
        let source = HeldSnapshotSource()
        let run = try await AppleReplyGenerator(source: source, clock: clock).openReply(
            to: ReplyContext(transcript: "a long story",
                             options: MultiModalKit.GenerationOptions(deadline: deadline)))
        let witness = Witness(run)
        #expect(await source.signals.heard("opened"), "the run asked the source for its stream")
        return Bench(clock: clock, source: source, run: run, witness: witness)
    }

    // MARK: the clock wins

    /// AC-264, F-4 = A: a source that NEVER finishes, two snapshots in,
    /// and the clock advanced past the deadline. The run ends
    /// `.finished(.deadline)` with the text so far, and the stream task
    /// was cancelled — the one thing this mind can do to stop the
    /// vendor's compute. The deadline is 200 ms on a manual clock: a mind
    /// that slept on wall time would never see it pass.
    @Test("a never-finishing source ends .finished(.deadline) with the snapshots so far (AC-264)")
    func clockEndsANeverFinishingSource() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let bench = try await Self.bench()
        let (clock, source) = (bench.clock, bench.source)
        let (run, witness) = (bench.run, bench.witness)
        source.push("Once upon")
        #expect(await witness.signals.heard("update:1"), "the first token reached the run's output")
        source.push("Once upon a time")
        #expect(await witness.signals.heard("update:2"), "the second token reached the run's output")
        #expect(await Self.parked(clock), "the deadline is asleep on THIS clock")

        await clock.advance(by: .milliseconds(200))

        #expect(await witness.signals.heard("ended"), "the clock ended the run")
        #expect(witness.updates == [.token("Once upon"), .token(" a time"), .finished(.deadline)],
                "what was said so far, then the clock's ending — one terminal")
        #expect(await source.signals.heard("terminated"), "the stream task was cancelled")
        #expect(source.sawCancellation, "cancelled, not finished: the vendor's compute was stopped")
        #expect(clock.sleeperCount == 0, "the fired sleeper is gone")
        witness.stop()
        withExtendedLifetime(run) {}   // alive through every assertion: `deinit` proved nothing here
    }

    /// The same ending through `reply(to:)`, with nothing said yet: the
    /// text is empty and the stop is `.deadline` — returned, not thrown.
    @Test("reply(to:) returns Reply(\"\", .deadline) when the clock ends a silent reply (AC-264)")
    func replyReturnsTheDeadlineEnding() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let clock = ManualClock()
        let source = HeldSnapshotSource()
        let generator = AppleReplyGenerator(source: source, clock: clock)
        let task = Task {
            try await generator.reply(to: ReplyContext(
                transcript: "a long story",
                options: MultiModalKit.GenerationOptions(deadline: .milliseconds(200))))
        }
        #expect(await source.signals.heard("opened"))
        #expect(await Self.parked(clock))
        await clock.advance(by: .milliseconds(200))
        let reply = try await task.value
        #expect(reply == Reply(text: "", stop: .deadline), "an ending, not a failure — nothing was said")
        #expect(clock.sleeperCount == 0)
    }

    // MARK: the stream wins

    /// The other side of the same clock: the source finishes BEFORE the
    /// deadline. The ending is the vendor's (`.unreported`, AC-235) and
    /// the sleeper is released the moment the terminal is taken — the
    /// count is read at `ended`, not after a wait, because the release
    /// happens inside the latch step that reports. Then the clock is
    /// advanced anyway: nothing wakes, nothing more is reported.
    @Test("a source that finishes first ends .finished(.unreported) and releases the sleeper (AC-264)")
    func streamEndsFirstAndReleasesTheSleeper() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let bench = try await Self.bench()
        let (clock, source) = (bench.clock, bench.source)
        let (run, witness) = (bench.run, bench.witness)
        #expect(await Self.parked(clock), "the deadline is asleep before the source ends")
        source.push("The end.")
        #expect(await witness.signals.heard("update:1"))

        source.finish()

        #expect(await witness.signals.heard("ended"), "the vendor's ending ended the run")
        #expect(witness.updates == [.token("The end."), .finished(.unreported)], "the vendor's own ending")
        #expect(clock.sleeperCount == 0, "the sleeper was cancelled when the terminal was taken")
        await clock.advance(by: .milliseconds(200))
        #expect(witness.updates.count == 2, "the deadline passing later adds nothing: one terminal")
        witness.stop()
        withExtendedLifetime(run) {}   // alive through every assertion: `deinit` proved nothing here
    }

    /// No deadline, no sleeper: the voice path's setting (AC-265's `nil`).
    /// Nothing is armed, so there is nothing an advance could wake.
    @Test("no deadline arms no sleeper (AC-264, AC-265)")
    func noDeadlineArmsNoSleeper() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let bench = try await Self.bench(deadline: nil)
        let (clock, source) = (bench.clock, bench.source)
        let witness = bench.witness
        #expect(clock.sleeperCount == 0, "nil deadline: nothing was put to sleep on the clock")
        await clock.advance(by: .seconds(3600))
        source.push("Still here.")
        #expect(await witness.signals.heard("update:1"))
        source.finish()
        #expect(await witness.signals.heard("ended"))
        #expect(witness.updates == [.token("Still here."), .finished(.unreported)],
                "an hour later, the reply was still open")
        witness.stop()
    }

    /// A `cancel()` releases the sleeper too — the seam's cancel contract
    /// ends the stream with NO terminal, and a cancelled reply must not
    /// leave its clock behind (the scripted mind's `stopClock` rule).
    @Test("cancel() ends with no terminal and releases the sleeper (AC-264)")
    func cancelReleasesTheSleeper() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let bench = try await Self.bench()
        let (clock, source) = (bench.clock, bench.source)
        let (run, witness) = (bench.run, bench.witness)
        #expect(await Self.parked(clock))
        await run.cancel()
        #expect(await witness.signals.heard("ended"), "cancel ended the stream")
        #expect(witness.updates.isEmpty, "no terminal after a cancel")
        #expect(clock.sleeperCount == 0, "the cancelled reply holds no sleeper")
        #expect(await source.signals.heard("terminated"))
        #expect(source.sawCancellation)
        witness.stop()
        withExtendedLifetime(run) {}   // alive through every assertion: `deinit` proved nothing here
    }

    // MARK: both at once — one latch, one terminal

    /// THE SERIALISATION PROOF. The deadline fires on the manual clock
    /// WHILE the source delivers its last snapshot and finishes — two
    /// tasks, no ordering between them. Whichever takes the retired
    /// latch first reports; the other finds it taken and reports nothing.
    /// The assertion is the INVARIANT, not the winner: exactly one
    /// terminal, it is one of the two endings, nothing follows it, and
    /// the clock holds no sleeper afterwards. Run twenty times in one
    /// test so both winners get a chance to show up in one run.
    @Test("the deadline and the last snapshot at once: exactly one terminal (AC-264, the latch)")
    func deadlineAndFinishAtOnceReportOneTerminal() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        var winners: Set<StopReason> = []
        for _ in 0..<20 {
            let bench = try await Self.bench()
            let (clock, source) = (bench.clock, bench.source)
            let (run, witness) = (bench.run, bench.witness)
            source.push("Once")
            #expect(await witness.signals.heard("update:1"))
            #expect(await Self.parked(clock))

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await clock.advance(by: .milliseconds(200)) }
                group.addTask {
                    source.push("Once more")
                    source.finish()
                }
            }

            #expect(await witness.signals.heard("ended"))
            let updates = witness.updates
            let terminals = ReplyConformanceKit.terminals(in: updates)
            #expect(terminals.count == 1, "one latch, one terminal: \(updates)")
            if case .finished(let stop)? = terminals.first {
                #expect(stop == .deadline || stop == .unreported, "one of the two endings: \(stop)")
                winners.insert(stop)
            } else {
                Issue.record("expected a .finished terminal, got \(updates)")
            }
            #expect(terminals.first == updates.last, "nothing follows the terminal")
            #expect(clock.sleeperCount == 0, "no sleeper survives either winner")
            witness.stop()
            withExtendedLifetime(run) {}   // alive through every assertion: `deinit` proved nothing here
        }
        // Recorded, not asserted: which endings won is the scheduler's
        // business, and a test that demanded both would be a flake by
        // design. The invariant above held on every round.
        print("deadline-vs-finish winners over 20 rounds: \(winners)")
    }

    /// The two orders, pinned deterministically beside the race above:
    /// the deadline first and THEN the source's finish adds nothing; the
    /// source first and THEN the deadline adds nothing. Each is the same
    /// latch seen from one side.
    @Test("deadline then finish, and finish then deadline: the second ending is a no-op (AC-264)")
    func eachOrderReportsOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        // Deadline first.
        do {
            let bench = try await Self.bench()
            let (clock, source) = (bench.clock, bench.source)
            let (run, witness) = (bench.run, bench.witness)
            #expect(await Self.parked(clock))
            await clock.advance(by: .milliseconds(200))
            #expect(await witness.signals.heard("ended"))
            source.push("too late")
            source.finish()
            #expect(witness.updates == [.finished(.deadline)], "the late snapshot and finish changed nothing")
            witness.stop()
            withExtendedLifetime(run) {}
        }
        // Finish first.
        do {
            let bench = try await Self.bench()
            let (clock, source) = (bench.clock, bench.source)
            let (run, witness) = (bench.run, bench.witness)
            #expect(await Self.parked(clock))
            source.push("Done.")
            #expect(await witness.signals.heard("update:1"))
            source.finish()
            #expect(await witness.signals.heard("ended"))
            await clock.advance(by: .milliseconds(200))
            #expect(witness.updates == [.token("Done."), .finished(.unreported)], "the clock changed nothing")
            witness.stop()
            withExtendedLifetime(run) {}
        }
    }
}
