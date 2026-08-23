import Foundation

/// What the machine was like while a row was measured (AC-148).
///
/// Carried per row rather than per sweep, because a repeated sweep heats the
/// phone and `ConservativeThermalPolicy` then sacrifices late settling
/// decodes — so a row taken at the end measures a different machine from a
/// row taken at the start (SPEC §104, H-5). A table without this column
/// cannot tell a slow decoder from a hot one.
public struct BenchConditions: Sendable, Equatable {
    public let thermal: String
    /// `nil` when the device cannot answer. NOT zero — `os_proc_available_memory`
    /// returns an ambiguous 0 on the very machines that have no limit
    /// (INSTRUMENTS §30), and a bench that printed "0 MB free" would be
    /// reporting a measurement it never made.
    public let freeMegabytes: Int?

    public init(thermal: String, freeMegabytes: Int?) {
        self.thermal = thermal
        self.freeMegabytes = freeMegabytes
    }
}

public struct BenchTiming: Sendable, Equatable {
    public let firstAudio: Duration
    public let total: Duration

    public init(firstAudio: Duration, total: Duration) {
        self.firstAudio = firstAudio
        self.total = total
    }
}

public struct BenchRow: Sendable, Equatable {
    public let configuration: BenchConfiguration
    public let run: Int
    public let timing: BenchTiming
    public let conditions: BenchConditions

    public init(configuration: BenchConfiguration, run: Int,
                timing: BenchTiming, conditions: BenchConditions) {
        self.configuration = configuration
        self.run = run
        self.timing = timing
        self.conditions = conditions
    }
}

/// Rows as a markdown table, in the shape INSTRUMENTS already uses (AC-150).
///
/// The phone's numbers reach the record by being pasted beside the Mac's, so
/// the two must be the same shape or the comparison is done by eye.
public enum BenchTable {
    public static func markdown(_ rows: [BenchRow]) -> String {
        var out = "| config | run | first audio | total | thermal | free |\n"
        out += "|---|---|---|---|---|---|\n"
        for row in rows {
            let free = row.conditions.freeMegabytes.map { "\($0) MB" } ?? "—"
            out += "| \(row.configuration.name)"
            out += " | \(row.run)"
            out += " | \(milliseconds(row.timing.firstAudio)) ms"
            out += " | \(milliseconds(row.timing.total)) ms"
            out += " | \(row.conditions.thermal)"
            out += " | \(free) |\n"
        }
        return out
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000)
            + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
