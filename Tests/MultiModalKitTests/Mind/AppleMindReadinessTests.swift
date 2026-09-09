import Foundation
import FoundationModels
import Testing
@testable import MultiModalKit

/// SPEC §175/5, the Apple verdicts (AC-238's wiring): the Apple mind's
/// three vendor reasons — and the OS floor the generator's `@available`
/// hides — become cases of the ONE `MindUnavailable` a screen switches
/// over, and `openReply` throws them as the contract's `ReplyFailure`.
@Suite("§175/5 · the Apple mind's readiness is the contract's verdict",
       .timeLimit(.minutes(1)))
struct AppleMindReadinessTests {

    // MARK: - the vendor's enum, mapped (pure, table-tested)

    /// One row per vendor case. `UnavailableReason` has public cases, so
    /// every row is written by hand — no model, no download, no Settings.
    @Test("every vendor reason lands on one contract verdict")
    func vendorReasonsMap() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let rows: [(SystemLanguageModel.Availability, MindUnavailable?)] = [
            (.available, nil),
            (.unavailable(.deviceNotEligible), .deviceCannotRun(.notEligible)),
            (.unavailable(.appleIntelligenceNotEnabled), .featureDisabled("Apple Intelligence")),
            (.unavailable(.modelNotReady), .modelDownloading)
        ]
        for (availability, expected) in rows {
            #expect(AppleMind.verdict(for: availability) == expected, "\(availability)")
        }
    }

    // MARK: - below the floor (the branch `#available` decides)

    /// `#available` cannot be faked on a running machine, so the branch
    /// is tested one call down: the sentence it builds, for both
    /// platforms, from the same `appleMindFloor` the readiness piece
    /// states. On this Mac (OS 26) `readiness()` never takes the branch;
    /// its two halves are proven separately and the seam between them
    /// is one `guard`.
    @Test("below the floor: the verdict names the platform and the Apple mind's floor")
    func belowFloorNamesThePlatform() {
        #expect(AppleMind.belowFloor(on: .iOS) == .osBelowFloor(required: "iOS 26"))
        #expect(AppleMind.belowFloor(on: .macOS) == .osBelowFloor(required: "macOS 26"))
        #expect(AppleMind.belowFloor(on: .iOS).description
            == "this device's operating system is older than the model needs — iOS 26 or later")
    }

    /// The ungated door agrees with the vendor on every OS-26 machine —
    /// available or not. On an older machine it must answer the floor
    /// instead of crashing on a type it cannot name.
    ///
    /// The vendor is read THREE times here (before, inside the door,
    /// after) and a download can complete between any two of them — on
    /// the Mac this was written on the model was mid-download. So the
    /// assertion is gated on an observable fact, not on the reads being
    /// "close enough": when the outer two reads agree, the world held
    /// still and the door's answer must be that one; when they differ,
    /// the world moved and the test says so instead of flaking (the 4v
    /// review's finding; the house rule — no timing assumptions).
    @Test("readiness() is askable on any OS and agrees with the vendor on this one")
    func readinessAgreesWithTheVendor() {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            #expect(AppleMind.readiness() == AppleMind.belowFloor(on: AppleMind.platform))
            return
        }
        let before = AppleMind.verdict(for: SystemLanguageModel.default.availability)
        let door = AppleMind.readiness()
        let demo = AppleReplyGenerator.availability
        let after = AppleMind.verdict(for: SystemLanguageModel.default.availability)
        guard before == after else {
            print("SKIPPED (the vendor's verdict changed mid-test: \(String(describing: before))"
                + " → \(String(describing: after))) — a still machine makes this test REAL")
            return
        }
        #expect(door == before, "the door is the vendor's verdict, mapped")
        #expect(demo == before, "the demo's reader and the door are one fact")
    }

    @Test("the platform the below-floor sentence names is this binary's")
    func platformIsCompileTime() {
        #if os(macOS)
        #expect(AppleMind.platform == .macOS)
        #else
        #expect(AppleMind.platform == .iOS)
        #endif
    }

    // MARK: - the door throws the verdict as the contract's failure

    @Test("openReply throws ReplyFailure.unavailable(verdict) at the door, never a run")
    func doorThrowsTheVerdict() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let generator = AppleReplyGenerator(source: source)
        for verdict: MindUnavailable in [.modelDownloading,
                                         .featureDisabled("Apple Intelligence"),
                                         .deviceCannotRun(.notEligible),
                                         .unknown("case 9")] {
            source.refuse(with: verdict)
            await #expect(throws: ReplyFailure.unavailable(verdict)) {
                _ = try await generator.openReply(to: "anything")
            }
        }
        #expect(source.recorded.isEmpty, "a refused door opens no generation")
    }

    @Test("the door is asked EVERY time — a download that completes is seen on the next call")
    func doorIsNeverCached() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let generator = AppleReplyGenerator(source: source)
        source.refuse(with: .modelDownloading)
        await #expect(throws: ReplyFailure.unavailable(.modelDownloading)) {
            _ = try await generator.openReply(to: "too early")
        }
        source.refuse(with: nil)
        let reply = try await generator.reply(to: ReplyContext(transcript: "now"))
        #expect(reply == Reply(text: "ok", stop: .unreported))
    }

    // MARK: - the words

    /// AC-238's wording rule, applied to the four new cases: none of
    /// them may say "Simulator" — a real phone was once told it was one.
    @Test("no Apple verdict says the word Simulator")
    func noAppleVerdictBlamesTheSimulator() {
        let verdicts: [MindUnavailable] = [
            .deviceCannotRun(.notEligible),
            .featureDisabled("Apple Intelligence"),
            .modelDownloading,
            .unknown("something new"),
            AppleMind.belowFloor(on: .iOS)
        ]
        for verdict in verdicts {
            #expect(!verdict.description.contains("Simulator"), "\(verdict)")
        }
    }

    @Test("the thrown failure speaks the verdict's own sentence — the screen and the turn agree")
    func failureCarriesTheVerdictWords() {
        #expect(ReplyFailure.unavailable(.modelDownloading).description
            == MindUnavailable.modelDownloading.description)
        #expect(ReplyFailure.unavailable(.featureDisabled("Apple Intelligence")).description
            == "Apple Intelligence is switched off in Settings")
    }
}
