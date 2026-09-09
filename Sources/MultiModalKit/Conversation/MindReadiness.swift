import Foundation

// READINESS, TYPED AND INJECTABLE — the verdict is a pure function of a
// value (4v, SPEC §175/5, F-5 = A in D-103, AC-238).
//
// Before 4v each mind asked the device itself, in its own words, at the
// moment of `openReply` — and one of those words was wrong: a real phone
// was told it was the Simulator (D-101's F1). A check that reads the
// hardware where it runs cannot be put on a table and read row by row.
// So the READING and the RULING are split: `DeviceReport.current` is
// the one line that touches the machine, and `MindReadiness.verdict`
// never does — it takes a report a test writes by hand in three lines
// and returns the same `MindUnavailable` the seam already speaks.
//
// A `DeviceProbing` protocol would have been injectable too (F-5's B);
// it was rejected because a value is faked by writing it, and a protocol
// is faked by writing a type. Nothing here is generic, nothing here
// awaits, nothing here is an actor: there is no state to protect.

// MARK: - the device, as a value

/// An operating-system version as three numbers. Our own value rather
/// than Foundation's `OperatingSystemVersion`, which is not `Equatable`
/// and so cannot sit in a report a test compares — and because a floor
/// a mind STATES (`MindNeeds.floor`) should be a literal, not a struct
/// filled from `ProcessInfo`.
public struct OSVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Foundation's triple, read once by `DeviceReport.current`.
    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    /// Numeric, component by component — `18.10` is newer than `18.9`,
    /// which a string comparison gets wrong.
    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The shortest honest spelling: "18", "18.2", "18.2.1" — a floor is
    /// stated as a person says it, and a person does not say "18.0.0".
    public var description: String {
        if patch != 0 { return "\(major).\(minor).\(patch)" }
        if minor != 0 { return "\(major).\(minor)" }
        return "\(major)"
    }
}

/// Which operating system the report describes. Carried on the REPORT
/// rather than read with `#if os(...)` inside the verdict, so the
/// verdict stays pure and a Mac's test can describe a phone — and so
/// the floor's rendering ("iOS 18", "macOS 15") has a name to print.
public enum Platform: Sendable, Equatable {
    case iOS
    case macOS

    /// The word that goes before the version number in a sentence.
    var name: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        }
    }
}

/// Whether the runtime has a GPU it can use. The core cannot ask Metal
/// (that is an MLX matter, behind the optional module), so the caller
/// that can says so.
public enum GPU: Sendable, Equatable {
    case available
    case absent
}

/// What is on disk (SPEC §175/6). The MLX piece PRODUCES this from its
/// manifest (AC-239); this piece only reads it.
public enum InstallState: Sendable, Equatable {
    /// Every file the manifest lists, at the size it says.
    case installed
    /// Files missing or shorter than the manifest says — named, so a
    /// person can be told which.
    case incomplete(files: [String])
    /// Nothing on disk.
    case absent
    /// Files present, but from a pre-4v install with no manifest to
    /// check them against — the phones in the field. Treated as
    /// installed: they ran yesterday, and a missing manifest is not
    /// evidence of a missing file.
    case installedUnverified
}

/// Everything the verdict needs to know about a device, and nothing it
/// does not. A test writes one by hand; a live device fills one through
/// `current(gpu:install:)`.
public struct DeviceReport: Sendable, Equatable {
    public var platform: Platform
    public var os: OSVersion
    public var isSimulator: Bool
    public var gpu: GPU
    /// Bytes REMAINING before this process's memory limit, or `nil`
    /// where the platform has no such number to give (a Mac has no
    /// limit — `MemoryHeadroom`'s whole reason to exist). `nil` is "I do
    /// not know", never "none left".
    public var memoryHeadroomBytes: Int?
    public var install: InstallState

    public init(platform: Platform,
                os: OSVersion,
                isSimulator: Bool,
                gpu: GPU,
                memoryHeadroomBytes: Int?,
                install: InstallState) {
        self.platform = platform
        self.os = os
        self.isSimulator = isSimulator
        self.gpu = gpu
        self.memoryHeadroomBytes = memoryHeadroomBytes
        self.install = install
    }

    /// THE ONE LIVE READER — the only lines in this file that touch the
    /// machine, kept small enough to be right by inspection because no
    /// test can exercise them. The GPU and the install state come from
    /// the caller: the core cannot ask Metal, and only a mind knows which
    /// files it needs.
    public static func current(gpu: GPU, install: InstallState) -> DeviceReport {
        #if os(macOS)
        let platform = Platform.macOS
        #else
        let platform = Platform.iOS
        #endif
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return DeviceReport(
            platform: platform,
            os: OSVersion(ProcessInfo.processInfo.operatingSystemVersion),
            isSimulator: isSimulator,
            gpu: gpu,
            memoryHeadroomBytes: MemoryHeadroomReader.read().bytes,
            install: install)
    }
}

// MARK: - what a mind asks of a device

/// What one mind requires. The mind states it: the library's floor is
/// iOS 18 / macOS 15 (D-091), the Apple mind's is 26 on both.
public struct MindNeeds: Sendable, Equatable {
    /// The oldest operating system the mind runs on, for the platform
    /// the report describes.
    public var floor: OSVersion
    /// The working set the mind expects to need, in bytes. `0` makes no
    /// claim, and a mind that makes no claim is never refused for memory.
    public var memoryBytes: Int

    public init(floor: OSVersion, memoryBytes: Int) {
        self.floor = floor
        self.memoryBytes = memoryBytes
    }
}

// MARK: - the verdict

/// The pure function. No state, no clock, no hardware: a report in, a
/// verdict or `nil` out, and the same answer every time for the same
/// report.
public enum MindReadiness {

    /// Why this device cannot run this mind — or `nil`, meaning it can.
    ///
    /// THE ORDER IS THE CONTRACT. The checks run in this sequence and the
    /// first that fails is the answer, so a device with two problems is
    /// told the one that a download, or anything else it can do, will
    /// not fix:
    ///
    /// 1. `report.os < needs.floor`            → `.osBelowFloor(required:)`
    /// 2. `report.isSimulator`                 → `.deviceCannotRun(.simulator)`
    /// 3. `report.gpu == .absent`              → `.deviceCannotRun(.noGPU)`
    /// 4. `report.install == .absent`          → `.weightsAbsent`
    /// 5. `report.install == .incomplete(f)`   → `.installIncomplete(files: f)`
    /// 6. headroom KNOWN, need CLAIMED, and headroom < need
    ///                                          → `.notEnoughMemory(needed:available:)`
    ///
    /// Memory comes LAST and refuses only on three facts together. An
    /// unknown headroom (`nil`) is not a refusal: D-092 is the record of
    /// what a number nobody had measured cost this project, and its
    /// lesson cuts both ways — the library must not refuse on a number
    /// it does not have either. Headroom equal to the need is enough.
    /// `.installedUnverified` passes step 4 and 5: the phones in the
    /// field are installed.
    public static func verdict(for report: DeviceReport, needs: MindNeeds) -> MindUnavailable? {
        if report.os < needs.floor {
            return .osBelowFloor(required: "\(report.platform.name) \(needs.floor)")
        }
        if report.isSimulator {
            return .deviceCannotRun(.simulator)
        }
        if report.gpu == .absent {
            return .deviceCannotRun(.noGPU)
        }
        switch report.install {
        case .absent:
            return .weightsAbsent
        case .incomplete(let files):
            return .installIncomplete(files: files)
        case .installed, .installedUnverified:
            break
        }
        if let available = report.memoryHeadroomBytes,
           needs.memoryBytes > 0,
           available < needs.memoryBytes {
            return .notEnoughMemory(needed: needs.memoryBytes, available: available)
        }
        return nil
    }
}
