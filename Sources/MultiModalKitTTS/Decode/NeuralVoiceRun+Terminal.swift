import AVFAudio
import Foundation
import MultiModalKit
import Synchronization

// `NeuralVoiceRun`, continued: how a run ENDS — the margin it reports, the
// terminal update it yields, and the teardown that gives the node back.
extension NeuralVoiceRun {
    private func reportMargin(completed: Bool) {
        // The HANDLER is not gated by the trace flag: a phone has no
        // stderr to read, and the phone is where this number is now
        // needed. The printing stays opt-in; the reporting does not.
        guard NeuralVoiceRun.traceSteps || onMargin != nil else { return }
        let (samples, firstStep, firstSamples, steps) = stepTotals.withLock {
            ($0.samples, $0.firstStep, $0.firstSamples, $0.steps)
        }
        // The number that sizes the NEXT cushion (AC-176). Computed from
        // the step record rather than from the totals beside it, because
        // the totals are exactly what cannot see a stall.
        let requiredCushion = DecodeDeficit.cushion(steps: steps)
        guard samples > 0, let last = stepClock.withLock({ $0 }) else { return }
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) * 1e-15
        }
        let wall = ms(birth.duration(to: last))
        let audio = Double(samples) / format.sampleRate * 1000
        var line = String(
            format: "   MARGIN . %.0f ms audio decoded in %.0f ms wall . RTF %.2f",
            audio, wall, wall / audio)
        if let first = firstStep {
            let steadyWall = ms(first.duration(to: last))
            let steadyAudio = Double(samples - firstSamples) / format.sampleRate * 1000
            if steadyAudio > 0 {
                let prefill = ms(birth.duration(to: first))
                let steady = steadyWall / steadyAudio
                line += String(format: " . prefill %.0f ms . STEADY %.3f", prefill, steady)
                onMargin?(DecodeMargin(audioMilliseconds: audio,
                                       wallMilliseconds: wall,
                                       prefillMilliseconds: prefill,
                                       steadyRealTimeFactor: steady,
                                       completed: completed,
                                       cushionMilliseconds: ms(leadInForce),
                                       requiredCushionMilliseconds: requiredCushion,
                                       // Multiply BEFORE dividing, as `DecodeStep`
                                       // does: 2400 × 1000 / 24000 is exactly 100,
                                       // 2400 / 24000 × 1000 is 0.1 × 1000 and 0.1
                                       // has no exact binary form. The test asserts
                                       // with `==` and it is this order that lets it.
                                       firstStepAudioMilliseconds:
                                           Double(firstSamples) * 1000 / format.sampleRate))
            }
        }
        if NeuralVoiceRun.traceSteps {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    func report(_ update: SynthesisUpdate, terminal: Bool) {
        // The margin says HOW the run ended: a failed run's numbers are
        // real, but its truncated length must not teach the learner what
        // replies look like (the 4m review's confirmed finding).
        if terminal {
            if case .failed = update { reportMargin(completed: false) } else { reportMargin(completed: true) }
        }
        out.yield(update)
        guard terminal else { return }
        // LATCH BEFORE TEARDOWN. `teardown` gives the player node back to
        // the engine, so anything still willing to touch that node after
        // this line aborts the process — see `retire`.
        retire()
        out.finish()
        teardown()
    }

    /// GIVE THE NODE BACK. Every reply attaches a fresh player to the
    /// engine, and until now none of them was ever detached — so a long
    /// conversation grew its audio graph without bound, and an engine
    /// handed in by a caller (the `renderingOn:` case) kept collecting
    /// dead nodes for as long as the app lived.
    ///
    /// On the mouth queue like every other touch of the player, and
    /// after the stream has finished, so nothing is still counting on it.
    private func teardown() {
        mouth.async { [self] in
            player.stop()
            host.detachFromPlayback(player)
        }
    }
}
