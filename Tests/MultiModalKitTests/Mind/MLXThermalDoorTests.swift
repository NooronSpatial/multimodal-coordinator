import Foundation
import MultiModalKitTesting
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// HEAT AT THE DOOR (4y, SPEC §187/2, AC-260, D-107 F-2 = A).
//
// Aura's R2: the thermal seam asked at `openReply`, before a run exists.
// The thermometer and the policy are injected at construction — the
// app's, the way tools are — and the shipped default refuses at
// `.critical` only, because the measured phone lived at `.serious`
// (INSTRUMENTS §26). A refusal is typed (`ReplyFailure.tooHot`) and
// countable. Every row scripts the thermometer; no test reads the room.

@Suite("AC-260 · the MLX door asks the thermal policy before it opens", .timeLimit(.minutes(1)))
struct MLXThermalDoorTests {

    private func mind(at state: ThermalState,
                      policy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(),
                      source: ScriptedTokenSource = ScriptedTokenSource(.tokens(["hi"])))
    -> MLXReplyGenerator {
        MLXReplyGenerator(source: source,
                          thermal: ScriptedThermalProvider(initial: state),
                          thermalPolicy: policy)
    }

    /// F-2 = A, state by state: three open, one refuses.
    @Test("the default policy opens at nominal, fair and serious, and refuses at critical",
          arguments: [ThermalState.nominal, .fair, .serious, .critical])
    func theDefaultPolicyStateByState(state: ThermalState) async throws {
        let mind = mind(at: state)
        if state == .critical {
            await #expect(throws: ReplyFailure.tooHot(.critical)) {
                _ = try await mind.openReply(to: "too hot to think")
            }
        } else {
            let run = try await mind.openReply(to: "cool enough")
            let updates = await ReplyConformanceKit.drain(run)
            #expect(updates == [.token("hi"), .finished(.unreported)],
                    "\(state): the door opens and the reply runs as before 4y")
        }
    }

    /// The app's policy replaces the default: one that refuses at
    /// `.serious` (the rejected default B, still a legal choice for an
    /// app that wants it) is obeyed, and the refusal names ITS state.
    @Test("an injected policy is the one asked, and the refusal carries the state it saw")
    func anInjectedPolicyIsObeyed() async throws {
        struct RefuseAtSerious: GenerationThermalPolicy {
            func allowGeneration(thermal: ThermalState) -> Bool { thermal < .serious }
        }
        await #expect(throws: ReplyFailure.tooHot(.serious)) {
            _ = try await mind(at: .serious, policy: RefuseAtSerious()).openReply(to: "warm")
        }
        _ = try await mind(at: .fair, policy: RefuseAtSerious()).openReply(to: "fine")
    }

    /// The ORDER: heat is asked BEFORE the readiness verdict. A phone
    /// too hot to generate is told so whatever is installed — so with
    /// the weights absent AND the phone critical, the answer is `.tooHot`.
    @Test("heat is asked before readiness: a hot phone with no weights hears .tooHot, not .unavailable")
    func heatSpeaksBeforeReadiness() async throws {
        let source = ScriptedTokenSource(.tokens(["hi"]))
        source.makeUnavailable(.unavailable(.weightsAbsent))
        await #expect(throws: ReplyFailure.tooHot(.critical)) {
            _ = try await mind(at: .critical, source: source).openReply(to: "hot and absent")
        }
        // Cooler, the readiness verdict is the one that speaks.
        await #expect(throws: ReplyFailure.unavailable(.weightsAbsent)) {
            _ = try await mind(at: .nominal, source: source).openReply(to: "cool and absent")
        }
    }

    /// The thermometer is read at EVERY door, never cached: a phone that
    /// cools between two turns is admitted on the second.
    @Test("the thermometer is read every time — a phone that cools is admitted on the next turn")
    func theThermometerIsReadEveryTime() async throws {
        let thermometer = ScriptedThermalProvider(initial: .critical)
        let mind = MLXReplyGenerator(source: ScriptedTokenSource(.tokens(["hi"])),
                                     thermal: thermometer)
        await #expect(throws: ReplyFailure.tooHot(.critical)) {
            _ = try await mind.openReply(to: "first, hot")
        }
        thermometer.push(.serious)
        let run = try await mind.openReply(to: "second, cooler")
        await run.cancel()
    }

    /// Countable, and its words are the seam's (piece 1 pinned them):
    /// the refusal a screen renders and a counter keys on is one case.
    @Test("the refusal is one typed case a caller can count")
    func theRefusalIsCountable() async throws {
        var refusals: [ReplyFailure] = []
        for _ in 0..<3 {
            do { _ = try await mind(at: .critical).openReply(to: "hot") } catch let failure as ReplyFailure {
                refusals.append(failure)
            }
        }
        #expect(refusals == [.tooHot(.critical), .tooHot(.critical), .tooHot(.critical)])
    }

    /// The defaults are the system's thermometer and the shipped policy
    /// — the constructor an app calls with nothing named asks the real
    /// device, so the Mac this runs on must be cool enough to open.
    @Test("the public constructor's defaults are the system thermometer and the shipped policy")
    func thePublicDefaultsAreTheSystemsAndTheShipped() async throws {
        let mind = MLXReplyGenerator(model: LocalMindModel(
            weights: URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-4y-\(UUID().uuidString)"),
            pressure: ScriptedPressureSource()))
        #expect(mind.thermal is SystemThermalProvider)
        #expect(mind.thermalPolicy is DefaultGenerationThermalPolicy)
        #expect(mind.clock is ContinuousClock)
    }
}
