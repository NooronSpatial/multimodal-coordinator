/// The sweep: order, invariants, and nothing else.
///
/// ## Why this type has no clock
///
/// It is not an oversight and it is not a style choice — it is how AC-147 is
/// enforced. A driver holding a `Clock` can always be made to "wait a bit and
/// hope", and every timing bug this project has recorded came from something
/// waiting for time instead of for a fact. `BenchSweep` cannot sleep, cannot
/// poll and cannot retry after an interval, because it has nothing to measure
/// an interval with. Readiness is `prepare`'s promise; timings are the
/// stage's measurement.
///
/// A reviewer checking AC-147 does not have to read the body. The absence of
/// a clock in the signature is the proof.
public enum BenchSweep {

    public enum Refusal: Error, Equatable {
        /// AC-146 — the stage's own words for why it will not measure.
        case refused(String)
    }

    /// Runs every configuration `runsEach` times and returns the rows.
    ///
    /// The human's settings are restored on every exit — completion, a
    /// throw from the stage, or cancellation between rows (AC-151).
    /// Cancellation returns the rows measured so far rather than throwing:
    /// a sweep stopped halfway still measured what it measured, and
    /// discarding that would make stopping expensive.
    public static func run<Stage: BenchStage>(
        _ configurations: [BenchConfiguration],
        runsEach: Int = 3,
        on stage: Stage
    ) async throws -> [BenchRow] {
        if let reason = await stage.refusalReason() {
            throw Refusal.refused(reason)
        }

        // Taken BEFORE the first change and restored after the last, so the
        // levers a sweep sets never outlive it.
        let saved = await stage.snapshot()
        var rows: [BenchRow] = []

        for configuration in configurations {
            // `1...0` is a TRAP, not an empty loop — Swift halts the
            // process on an invalid ClosedRange. An instrument must never
            // be the thing that kills the app it measures.
            for run in stride(from: 1, through: runsEach, by: 1) {
                if Task.isCancelled {
                    await stage.restore(saved)
                    return rows
                }
                do {
                    // ORDER, and each step is a criterion:
                    //   prepare  — returns only when the new config is UP
                    //   reset    — so the row counts this run, not the setup
                    //   sample   — the machine as it is for THIS row
                    //   measure  — the stage times it; we hold no clock
                    try await stage.prepare(configuration)
                    await stage.resetCounters()
                    let conditions = await stage.conditions()
                    let timing = try await stage.measure()
                    rows.append(BenchRow(configuration: configuration,
                                         run: run,
                                         timing: timing,
                                         conditions: conditions))
                } catch {
                    await stage.restore(saved)
                    throw error
                }
            }
        }

        await stage.restore(saved)
        return rows
    }
}
