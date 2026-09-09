import Testing
@testable import MultiModalKit

/// AC-238 (SPEC §175/5, F-5 = A, D-103): readiness is a PURE function of
/// a `DeviceReport` a test writes by hand. Every row below is a device
/// that never existed, described in three lines, and the verdict must
/// be the one the doc comment on `MindReadiness.verdict` promises — in
/// that order, because the order is the contract.
@Suite("AC-238 · readiness is a pure verdict over a hand-written device report")
struct MindReadinessTests {

    // MARK: - the fixtures

    /// A phone that can run anything: on the floor, real hardware, a GPU,
    /// room to spare, every file present. Each row below breaks ONE
    /// thing about it.
    static let healthy = DeviceReport(
        platform: .iOS,
        os: OSVersion(major: 18),
        isSimulator: false,
        gpu: .available,
        memoryHeadroomBytes: 4 * 1_073_741_824,
        install: .installed)

    /// The library's own floor (iOS 18, D-091) and a 2 GiB working set —
    /// binary-exact, like every number in this file.
    static let needs = MindNeeds(floor: OSVersion(major: 18), memoryBytes: 2 * 1_073_741_824)

    static func report(_ change: (inout DeviceReport) -> Void) -> DeviceReport {
        var copy = healthy
        change(&copy)
        return copy
    }

    /// One row per verdict, in the order the contract names them.
    struct Row {
        let name: String
        let report: DeviceReport
        let expected: MindUnavailable?
    }

    static let table: [Row] = [
        Row(name: "OS below the floor",
            report: report { $0.os = OSVersion(major: 17, minor: 6, patch: 1) },
            expected: .osBelowFloor(required: "iOS 18")),
        Row(name: "the Simulator",
            report: report { $0.isSimulator = true },
            expected: .deviceCannotRun(.simulator)),
        Row(name: "no GPU",
            report: report { $0.gpu = .absent },
            expected: .deviceCannotRun(.noGPU)),
        Row(name: "no weights",
            report: report { $0.install = .absent },
            expected: .weightsAbsent),
        Row(name: "a short file",
            report: report { $0.install = .incomplete(files: ["model.safetensors"]) },
            expected: .installIncomplete(files: ["model.safetensors"])),
        Row(name: "headroom below the need",
            report: report { $0.memoryHeadroomBytes = 1_073_741_824 },
            expected: .notEnoughMemory(needed: 2 * 1_073_741_824, available: 1_073_741_824)),
        Row(name: "healthy",
            report: healthy,
            expected: nil)
    ]

    // MARK: - the table

    @Test("every verdict, one row each, and the healthy phone is ready")
    func everyVerdictHasARow() {
        for row in Self.table {
            let verdict = MindReadiness.verdict(for: row.report, needs: Self.needs)
            #expect(verdict == row.expected, "\(row.name)")
        }
    }

    // MARK: - the rules around the numbers

    /// D-092's lesson, applied: the library never refuses on a number it
    /// does not have. A Mac reports no headroom at all (INSTRUMENTS,
    /// `MemoryHeadroom`), and a Mac can run the mind.
    @Test("an unknown headroom with a memory need is NOT a refusal")
    func unknownHeadroomIsNotARefusal() {
        let report = Self.report { $0.memoryHeadroomBytes = nil }
        #expect(MindReadiness.verdict(for: report, needs: Self.needs) == nil)
    }

    @Test("headroom exactly equal to the need is enough")
    func equalHeadroomIsEnough() {
        let report = Self.report { $0.memoryHeadroomBytes = Self.needs.memoryBytes }
        #expect(MindReadiness.verdict(for: report, needs: Self.needs) == nil)
    }

    @Test("a mind that claims no memory is never refused for memory")
    func noClaimNoRefusal() {
        let report = Self.report { $0.memoryHeadroomBytes = 1 }
        let needs = MindNeeds(floor: OSVersion(major: 18), memoryBytes: 0)
        #expect(MindReadiness.verdict(for: report, needs: needs) == nil)
    }

    /// The phones in the field: a pre-4v install with no manifest is
    /// installed, not suspect (§175/6).
    @Test("an unverified install counts as installed")
    func unverifiedInstallIsInstalled() {
        let report = Self.report { $0.install = .installedUnverified }
        #expect(MindReadiness.verdict(for: report, needs: Self.needs) == nil)
    }

    // MARK: - the order is the contract

    /// Two rules tripped at once: the FIRST in the documented order wins.
    /// A Simulator with no weights is told it is a Simulator — a download
    /// would not help it.
    @Test("a report that trips two rules gets the first one")
    func firstRuleWins() {
        let simulatorWithoutWeights = Self.report {
            $0.isSimulator = true
            $0.install = .absent
        }
        #expect(MindReadiness.verdict(for: simulatorWithoutWeights, needs: Self.needs)
                == .deviceCannotRun(.simulator))

        let oldOSOnSimulator = Self.report {
            $0.os = OSVersion(major: 17)
            $0.isSimulator = true
        }
        #expect(MindReadiness.verdict(for: oldOSOnSimulator, needs: Self.needs)
                == .osBelowFloor(required: "iOS 18"))
    }

    // MARK: - the floor's words

    @Test("the floor is rendered with the report's platform name")
    func floorIsRenderedForThePlatform() {
        let oldMac = Self.report {
            $0.platform = .macOS
            $0.os = OSVersion(major: 14, minor: 7)
        }
        let macNeeds = MindNeeds(floor: OSVersion(major: 15), memoryBytes: 0)
        #expect(MindReadiness.verdict(for: oldMac, needs: macNeeds) == .osBelowFloor(required: "macOS 15"))

        let pointFloor = MindNeeds(floor: OSVersion(major: 18, minor: 2), memoryBytes: 0)
        let oldPhone = Self.report { $0.os = OSVersion(major: 18, minor: 1, patch: 9) }
        #expect(MindReadiness.verdict(for: oldPhone, needs: pointFloor) == .osBelowFloor(required: "iOS 18.2"))
    }

    @Test("versions compare as numbers, not as words")
    func versionsCompareNumerically() {
        #expect(OSVersion(major: 18) < OSVersion(major: 26))
        #expect(OSVersion(major: 18, minor: 10) > OSVersion(major: 18, minor: 9))
        #expect(OSVersion(major: 18, minor: 0, patch: 1) > OSVersion(major: 18))
        #expect(OSVersion(major: 18) == OSVersion(major: 18, minor: 0, patch: 0))
    }

    // MARK: - the wording rule

    /// AC-238's last sentence: a real phone was once told it was the
    /// Simulator (D-101's F1). The word appears in exactly ONE rendering —
    /// the verdict that IS the Simulator — and nowhere else.
    @Test("only the Simulator verdict says Simulator")
    func onlyTheSimulatorSaysSimulator() {
        let verdicts: [MindUnavailable] = [
            .osBelowFloor(required: "iOS 18"),
            .deviceCannotRun(.simulator),
            .deviceCannotRun(.noGPU),
            .weightsAbsent,
            .installIncomplete(files: ["model.safetensors"]),
            .notEnoughMemory(needed: 2 * 1_073_741_824, available: 1_073_741_824)
        ]
        for verdict in verdicts {
            let saysSimulator = verdict.description.lowercased().contains("simulator")
            let isSimulator = verdict == .deviceCannotRun(.simulator)
            #expect(saysSimulator == isSimulator, "\(verdict)")
        }
    }

    /// Two floors, per platform: the library's own (the MLX mind) and the
    /// Apple mind's. A phone on iOS 18 is ready for the first and one
    /// release short for the second — the verdict names the floor it missed.
    @Test("the platform knows both floors: the library's and the Apple mind's")
    func platformFloors() {
        #expect(Platform.iOS.libraryFloor == OSVersion(major: 18))
        #expect(Platform.macOS.libraryFloor == OSVersion(major: 15))
        #expect(Platform.iOS.appleMindFloor == OSVersion(major: 26))
        let phone = DeviceReport(platform: .iOS, os: OSVersion(major: 18, minor: 6), isSimulator: false,
                                 gpu: .available, memoryHeadroomBytes: nil, install: .installed)
        #expect(MindReadiness.verdict(for: phone, needs: MindNeeds(floor: phone.platform.libraryFloor,
                                                                    memoryBytes: 0)) == nil)
        #expect(MindReadiness.verdict(for: phone, needs: MindNeeds(floor: phone.platform.appleMindFloor,
                                                                    memoryBytes: 0))
                == .osBelowFloor(required: "iOS 26"))
    }

}
