// THE APPLE MIND'S HEAT CHECK AT THE DOOR (4y piece 3, AC-260, D-107 F-2 = A).
//
// `openReply` asks the injected `GenerationThermalPolicy` with the injected
// thermometer's state BEFORE it asks the vendor's availability verdict,
// and a refusal is the typed, countable `ReplyFailure.tooHot(state)` —
// thrown at the door, so no run exists and no session was born. The
// thermometer is a `ScriptedThermalProvider`, never the room (Thermal.swift's
// own doctrine: no test depends on a room's temperature), and the source
// behind the door is the recording one from `AppleOptionsTests`, so the
// test can read whether the vendor was asked at all.
//
// What is NOT here, and why: admission (`admit(needing:)`, AC-258/259) and
// memory pressure (AC-261..263) are the MLX mind's — that mind allocates
// the weights itself. The vendor's framework manages its own memory behind
// `LanguageModelSession`; this library has no allocation to admit and no
// prefill of its own to release, so it builds neither here.

import Foundation
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKit

// MARK: - a thermometer that counts how often it was read

/// Reads one fixed state and COUNTS the reads — the witness for "read
/// once at the door" (the reentrancy law's shape at this door: one read,
/// one decision, no second look after an await).
final class CountingThermometer: ThermalStateProviding, @unchecked Sendable {
    private let fixed: ThermalState
    private let count = Mutex(0)

    init(_ state: ThermalState) { self.fixed = state }

    var reads: Int { count.withLock { $0 } }
    var current: ThermalState {
        count.withLock { $0 += 1 }
        return fixed
    }
    func transitions() -> AsyncStream<ThermalState> { AsyncStream { $0.finish() } }
}

/// An app's own policy, stricter than the shipped one: refuses at
/// `.serious`. Exists so the tests can prove the INJECTED policy is the
/// one asked, not the default hard-wired.
struct RefusesAtSerious: GenerationThermalPolicy {
    func allowGeneration(thermal: ThermalState) -> Bool { thermal < .serious }
}

@Suite("AC-260 · the Apple mind asks the thermal policy at the door",
       .timeLimit(.minutes(1)))
struct AppleHeatTests {

    /// Opens a reply on a mind whose thermometer reads `state`, and
    /// returns the failure the door threw — or nil when it opened.
    @available(macOS 26.0, iOS 26.0, *)
    private static func door(at state: ThermalState,
                             policy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(),
                             source: RecordingSnapshotSource = RecordingSnapshotSource()
    ) async -> ReplyFailure? {
        let generator = AppleReplyGenerator(source: source,
                                            thermal: ScriptedThermalProvider(initial: state),
                                            thermalPolicy: policy)
        do {
            let run = try await generator.openReply(to: ReplyContext(transcript: "hello"))
            _ = await ReplyConformanceKit.drain(run)
            return nil
        } catch let failure as ReplyFailure {
            return failure
        } catch {
            Issue.record("the door threw something that is not a ReplyFailure: \(error)")
            return nil
        }
    }

    // MARK: the four states, through the shipped default

    /// F-2 = A, on the REAL generator: `.critical` refuses with the state
    /// on the case, and the three cooler states open a run and drain it.
    /// Listed by hand and switched without a `default`, so a fifth state
    /// stops this file compiling instead of sitting outside the table
    /// (the `AdmissionSeamTests` pattern).
    @Test("the default refuses at .critical only — each state scripted (AC-260, F-2 = A)")
    func defaultRefusesAtCriticalOnly() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let every: [ThermalState] = [.nominal, .fair, .serious, .critical]
        for state in every {
            let source = RecordingSnapshotSource()
            let failure = await Self.door(at: state, source: source)
            switch state {
            case .nominal, .fair, .serious:
                #expect(failure == nil, "\(state) generates")
                #expect(source.recorded.count == 1, "\(state): the source was asked once")
            case .critical:
                #expect(failure == .tooHot(.critical), "the shipped default refuses at .critical")
                #expect(source.recorded.isEmpty, "refused at the door: the source was never asked")
            }
        }
    }

    // MARK: the injected policy is the one asked

    @Test("an app's stricter policy refuses at .serious — the INJECTED policy decides (AC-260)")
    func injectedPolicyIsAsked() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let refused = await Self.door(at: .serious, policy: RefusesAtSerious())
        #expect(refused == .tooHot(.serious), "the state on the case is WHERE the app's policy refused")
        let opened = await Self.door(at: .fair, policy: RefusesAtSerious())
        #expect(opened == nil, "the same policy lets .fair through")
    }

    // MARK: heat is asked BEFORE the vendor's verdict

    /// The order at the door: heat first, then availability. A source
    /// that refuses at its own door (`.modelDownloading`) on a `.critical`
    /// thermometer throws `.tooHot`, not `.unavailable` — the vendor was
    /// never asked.
    @Test("heat is asked before the availability verdict (AC-260)")
    func heatBeforeTheVerdict() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        source.refuse(with: .modelDownloading)
        let hot = await Self.door(at: .critical, source: source)
        #expect(hot == .tooHot(.critical), "heat wins the door when both would refuse")
        let cool = await Self.door(at: .nominal, source: source)
        #expect(cool == .unavailable(.modelDownloading), "cool: the verdict is asked next, and it refuses")
    }

    // MARK: read once, counted

    /// The thermometer is read ONCE per `openReply` — one read, one
    /// decision — and a refusal is countable: three doors on a `.critical`
    /// thermometer are three `.tooHot(.critical)`, equal values a caller
    /// can add up.
    @Test("the thermometer is read once per door, and refusals count (AC-260)")
    func readOnceAndCountable() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let thermometer = CountingThermometer(.critical)
        let generator = AppleReplyGenerator(source: RecordingSnapshotSource(), thermal: thermometer)
        var refusals: [ThermalState] = []
        for _ in 0..<3 {
            do {
                _ = try await generator.openReply(to: ReplyContext(transcript: "hello"))
                Issue.record("a .critical door opened")
            } catch ReplyFailure.tooHot(let state) {
                refusals.append(state)
            }
        }
        #expect(refusals == [.critical, .critical, .critical], "three doors, three countable refusals")
        #expect(thermometer.reads == 3, "one read per door, never a second look")
    }

    /// The public initialiser's defaults are the shipped ones: the real
    /// thermometer and the `.critical`-only policy. Read back by type so
    /// a default silently swapped for a stricter one is caught.
    @Test("the public initialiser defaults to the real thermometer and the shipped policy (AC-260)")
    func publicDefaults() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let generator = AppleReplyGenerator()
        #expect(generator.thermal is SystemThermalProvider)
        #expect(generator.thermalPolicy is DefaultGenerationThermalPolicy)
    }
}
