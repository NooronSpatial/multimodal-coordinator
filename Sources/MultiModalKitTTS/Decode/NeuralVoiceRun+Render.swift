import AVFAudio
import Foundation
import MultiModalKit
import Synchronization

// `NeuralVoiceRun`, continued: the decode-and-render half — turning a
// queued phrase into decoded samples, and those samples into buffers the
// player node speaks.
extension NeuralVoiceRun {
    // MARK: - decode, then render

    func speak(_ text: String) async {
        // NOTHING TO SAY, SO NOTHING IS DECODED (AC-106).
        //
        // A whitespace or punctuation-only phrase gives this model no
        // reason to stop, so it decodes toward its 245-step cap — about
        // 19.6 seconds of audio for a phrase containing nothing — and
        // the turn loop waits inline for every one of them. The
        // accounting below still runs, unchanged: the phrase is counted
        // as done, which is what keeps `finished` honest.
        //
        // The Apple mouth deliberately does NOT get this guard. Its
        // failure mode is different (it may decline to REPORT on an
        // unspeakable utterance, which the counting already survives),
        // it is proven, and it costs nothing there.
        if SpeechPhraser.hasSpeakableContent(text) {
            do {
                // The batching pin that used to sit here moved to
                // `TTSKitDecoder` with the comment that explains it: it is
                // about the VENDOR's own branching, so it belongs beside
                // the vendor (D-053 F-6).
                try await decoder.decode(
                    text, temperature: temperature
                ) { [weak self] samples in
                    guard let self else { return false }
                    // The decode's own cancellation channel: returning false
                    // stops it at the next step. The ticket upstream is still
                    // the guarantee; this only saves the compute.
                    guard self.state.withLock({ !$0.cancelled }) else { return false }
                    // DIAGNOSTIC (AC-102): is a slow first sound the MODEL's
                    // prefill or OUR integration? A step trace separates
                    // them — many fast steps means the model streams and we
                    // are holding it up somewhere; one long wait then a
                    // flood means the wait is prefill.
                    // ALWAYS COUNTED, never gated. This accumulation sat
                    // inside `if traceSteps` for exactly one commit, and
                    // that commit shipped a comment promising the
                    // opposite — so on a phone, where no environment
                    // variable can be set, `samples` stayed 0, the guard
                    // in `reportMargin` returned early, and the screen
                    // that was added to answer the field's question would
                    // have stayed blank. A dead instrument costs a whole
                    // field trip, which is the most expensive thing in
                    // this project.
                    let now = ContinuousClock().now
                    self.stepClock.withLock { $0 = now }
                    self.stepTotals.withLock {
                        if $0.firstStep == nil {
                            $0.firstStep = now
                            $0.firstSamples = samples.count
                        }
                        $0.samples += samples.count
                    }
                    self.render(samples)
                    return true
                }
            } catch {
                let live = state.withLock { !$0.cancelled }
                if live { report(.failed("neural voice: \(error)"), terminal: true) }
            }
        }

        // THE LIVENESS STEP. A reply shorter than the lead has queued
        // everything it will ever queue, and the target will never be
        // reached. If nothing released it here, the player would never
        // start, no buffer would ever report played, `finished` would
        // never fire, and the turn would hang — with the audio sitting
        // complete and silent in the node.
        //
        // This was the ONLY site that asked the full question, which is
        // exactly why D-055's hole opened in the other one. The question
        // lives in `owed(by:)` now; this site's remaining job is the
        // decrement that makes the answer true.
        let owed = state.withLock { guarded -> Owed in
            guarded.phrasesInFlight -= 1
            return Self.owed(by: guarded)
        }
        settle(owed)
    }

    /// The reply is complete: whatever is held is all there will ever be.
    /// Runs on the mouth queue, like every other touch of the player.
    func releaseLead() {
        let start = state.withLock { guarded -> Bool in
            guard !guarded.cancelled else { return false }
            return guarded.lead.noMoreAudio()
        }
        if start {
            player.play()
            report(.started, terminal: false)
        }
    }

    /// One decode step's samples, handed to the player.
    private func render(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Only the SAMPLES cross onto the queue: `[Float]` is Sendable,
        // `AVAudioPCMBuffer` is not, so the buffer is born and used
        // entirely on the mouth's own thread — the same rule the Apple
        // mouth learned, for the same reason.
        state.withLock { $0.scheduled += 1 }

        mouth.async { [self] in
            // EVERY early return from here must balance the count above,
            // or `finished` never fires and the turn hangs forever — the
            // liveness promise the conformance kit exists to catch.
            guard state.withLock({ !$0.cancelled }) else { return bufferPlayed() }
            guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData
            else { return bufferPlayed() }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel[0].update(from: source.baseAddress!, count: samples.count)
            }
            // `.dataPlayedBack`, not the default. The legacy overload
            // reports when the player has CONSUMED a buffer, which can be
            // a buffer or more before any of it reaches the room — and
            // this count is what decides `.finished`, whose whole meaning
            // under D-029 is "the room is quiet". Consumed is not quiet.
            player.scheduleBuffer(buffer, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.bufferPlayed()
            }
            // AUDIBLE now means THE PLAYER WAS STARTED, which is a
            // stricter reading of D-045 F-2 than the one this file
            // shipped with: scheduling a buffer onto a node that is not
            // playing puts no sound in the room. `PlaybackLead` owns the
            // once-only guarantee, so there is no separate flag to keep
            // honest.
            let start = state.withLock { guarded -> Bool in
                guard !guarded.cancelled else { return false }
                return guarded.lead.queue(.microseconds(
                    Int((Double(samples.count) / format.sampleRate * 1_000_000).rounded())))
            }
            if start {
                player.play()
                report(.started, terminal: false)
            }
        }
    }

    /// The third site that learns a reply became complete, and the third
    /// through the funnel (D-055 = B).
    ///
    /// Its answer can only be `.finish` or `.nothing` in practice: reaching
    /// here means a buffer was HEARD, so the player was started, so
    /// `PlaybackLead.noMoreAudio()` already returned its one `true` and a
    /// `.releaseLead` answer would do nothing. Routing it anyway is the
    /// point of a funnel — the site does not get to decide which answers
    /// are possible, and a future change to the counters cannot leave this
    /// one behind.
    private func bufferPlayed() {
        let owed = state.withLock { guarded -> Owed in
            guarded.played += 1
            return Self.owed(by: guarded)
        }
        settle(owed)
    }
}
