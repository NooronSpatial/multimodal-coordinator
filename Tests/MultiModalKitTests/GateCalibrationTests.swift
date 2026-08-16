import Testing
@testable import MultiModalKit

/// WHERE TO PUT THE GATE (AC-97), proven without a microphone.
///
/// Every value here is a power of two, so every expectation is
/// binary-exact and no assertion depends on how a float rounded.
@Suite("Gate calibration — between the room and the voice")
struct GateCalibrationTests {

    /// THE FIELD CASE, in exact arithmetic. Ryad's phone measured a
    /// quiet floor near 0.002 and speech near 0.032 with the neural
    /// mouth selected, while his gate sat at 0.060 — above his own
    /// voice, so nothing ever opened and the state read `idle` forever.
    /// 2⁻⁹ and 2⁻⁵ are those numbers to the nearest exact power of two.
    @Test("a quiet room and a normal voice put the gate between them")
    func theFieldCase() {
        let quiet: Float = 0.001953125      // 2⁻⁹ ≈ the measured 0.002
        let speech: Float = 0.03125         // 2⁻⁵ ≈ the measured 0.032
        #expect(GateCalibration.suggestedGate(quiet: quiet, speech: speech)
                == .gate(0.0078125))        // 2⁻⁷ — four times clear of each
    }

    /// The geometric midpoint is the whole design, so it is asserted
    /// rather than assumed: equally far from both failures, measured in
    /// RATIOS, because loudness is a ratio.
    @Test("the midpoint is geometric — equally clear of both mistakes")
    func midpointIsGeometric() {
        guard case .gate(let gate) = GateCalibration.suggestedGate(
            quiet: 0.001953125, speech: 0.03125) else {
            Issue.record("expected a gate"); return
        }
        #expect(gate / 0.001953125 == 4, "four times above the room")
        #expect(0.03125 / gate == 4, "four times below the voice")
    }

    @Test("a voice barely above the room cannot carry a gate")
    func tooCloseIsRefused() {
        // Ratio 2, under the minimum of 3: there is no room to stand
        // between them, and inventing a number would be a coin toss.
        #expect(GateCalibration.suggestedGate(quiet: 0.25, speech: 0.5)
                == .tooClose(quiet: 0.25, speech: 0.5))
    }

    @Test("exactly the minimum ratio is accepted")
    func theBoundaryIsAccepted() {
        // 3× exactly. The floor (quiet × 2) wins over the geometric
        // midpoint here, which is the clamp doing its job.
        guard case .gate = GateCalibration.suggestedGate(quiet: 0.25, speech: 0.75)
        else { Issue.record("the boundary must be usable"); return }
    }

    /// A SILENT ROOM REPORTS ZERO, and the geometric midpoint of
    /// anything with zero is zero — a gate that opens an utterance on
    /// nothing at all. That is the degenerate case that would ship a
    /// permanently-open microphone.
    @Test("a perfectly silent room still yields a usable gate")
    func silenceDoesNotProduceAZeroGate() {
        guard case .gate(let gate) = GateCalibration.suggestedGate(
            quiet: 0, speech: 0.5) else {
            Issue.record("expected a gate"); return
        }
        #expect(gate > 0, "a gate of zero opens on silence")
        #expect(gate <= 0.25, "and it must still sit below the voice")
    }

    @Test("no speech at all is refused rather than guessed")
    func noSpeechIsRefused() {
        #expect(GateCalibration.suggestedGate(quiet: 0.25, speech: 0)
                == .tooClose(quiet: 0.25, speech: 0))
    }

    /// The gate must never land at or above the voice it is meant to
    /// let through — that is the exact failure that produced `idle`
    /// forever on the phone.
    @Test("the gate always sits strictly below the speech it must pass")
    func neverAboveTheVoice() {
        for exponent in 2...10 {
            let speech = Float(1) / Float(1 << exponent)
            let quiet = speech / 8
            guard case .gate(let gate) = GateCalibration.suggestedGate(
                quiet: quiet, speech: speech) else {
                Issue.record("expected a gate at 2^-\(exponent)"); continue
            }
            #expect(gate < speech, "a gate at or above the voice hears nothing")
            #expect(gate > quiet, "a gate at or below the room never closes")
        }
    }
}
