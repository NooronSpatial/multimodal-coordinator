import AVFAudio
import Foundation
import MultiModalKit
import Synchronization
import TTSKit

/// ONE spoken reply from the neural voice (SPEC AC-101, D-045).
///
/// The shape deliberately mirrors `AppleSynthesisRun`, because that one
/// is proven: a `SpeechPhraser` upstream, evidence-based updates, and a
/// queued/finished count deciding when the room is quiet. What differs
/// is who renders — and that difference is the milestone's second prize.
///
/// **We render, TTSKit only decodes (D-045 F-1 = B).** `generate` hands
/// back ~80 ms of PCM per step; those samples are scheduled on a player
/// node on an `AVAudioEngine` we control. D-043 measured that iOS voice
/// processing cancels only what its OWN audio unit renders, so a reply
/// rendered here is the first one the canceller can possibly see. The
/// cost, accepted in the ruling: pre-buffering and resampling become
/// ours to get wrong.
///
/// `@unchecked Sendable`, with the same proof shape as the Apple mouth:
/// all mutable state lives behind one `Mutex`, nothing suspends under
/// it, no continuation is resumed while it is held, and every touch of
/// the engine happens on one serial queue.
final class NeuralVoiceRun: SynthesisRun, @unchecked Sendable {
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation

    private let kit: TTSKit
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    /// The engine's one thread. Same reasoning as the Apple mouth: FIFO
    /// matters, and Swift actors make no ordering promise between two
    /// independent callers.
    private let mouth = DispatchQueue(label: "dev.nooron.MultiModalKit.neuralMouth")

    private struct Guarded {
        var phraser = SpeechPhraser()
        var scheduled = 0          // buffers handed to the player
        var played = 0             // buffers the player reported done
        var phrasesInFlight = 0    // decodes started but not finished
        var startedReported = false
        var tokensFinished = false
        var cancelled = false
    }
    private let state = Mutex(Guarded())
    /// Step tracing, opt-in through the environment so it costs nothing
    /// when nobody is asking.
    static let traceSteps = ProcessInfo.processInfo.environment["MMK_TRACE_TTS"] == "1"
    private let stepClock = Mutex<ContinuousClock.Instant?>(nil)
    private let birth = ContinuousClock().now
    private struct Totals { var samples = 0 }
    private let stepTotals = Mutex(Totals())

    /// THE MARGIN QUESTION (AC-102). A streaming voice must decode audio
    /// at least as fast as the ear drinks it. The real-time factor is
    /// decode wall time divided by audio produced: below 1.0 the voice
    /// runs ahead of the speaker, at 1.0 it is exactly keeping up —
    /// which on a slower machine means silence gaps mid-sentence.
    ///
    /// It reports itself on stderr rather than through a return value,
    /// and that is deliberate: this type is internal, and widening a
    /// library's public surface to let a measuring tool peek in is a
    /// worse trade than a printed line.
    private func reportMargin() {
        guard NeuralVoiceRun.traceSteps else { return }
        let samples = stepTotals.withLock { $0.samples }
        guard samples > 0, let last = stepClock.withLock({ $0 }) else { return }
        let elapsed = birth.duration(to: last)
        let wall = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) * 1e-15
        let audio = Double(samples) / format.sampleRate * 1000
        FileHandle.standardError.write(Data(String(
            format: "   MARGIN · %.0f ms audio decoded in %.0f ms wall · RTF %.2f\n",
            audio, wall, wall / audio).utf8))
    }

    init(kit: TTSKit, engine: AVAudioEngine, sampleRate: Double) throws {
        self.kit = kit
        self.engine = engine
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw TurnFailure.synthesisFailed("the neural voice's format was refused")
        }
        self.format = format

        var handle: AsyncStream<SynthesisUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
    }

    // MARK: - the seam

    func feed(_ token: String) async {
        let phrases = state.withLock { s -> [String] in
            guard !s.cancelled else { return [] }
            let completed = s.phraser.feed(token)
            s.phrasesInFlight += completed.count
            return completed
        }
        for phrase in phrases { await speak(phrase) }
    }

    func finishTokens() async {
        enum Outcome { case speak(String), finishNow, wait }
        let outcome = state.withLock { s -> Outcome in
            guard !s.cancelled, !s.tokensFinished else { return .wait }
            s.tokensFinished = true
            if let rest = s.phraser.flush() {
                s.phrasesInFlight += 1
                return .speak(rest)
            }
            // Nothing left to say, and nothing still sounding: a reply of
            // pure whitespace ends here, silently.
            return (s.phrasesInFlight == 0 && s.scheduled == s.played) ? .finishNow : .wait
        }
        switch outcome {
        case .speak(let rest): await speak(rest)
        case .finishNow: report(.finished, terminal: true)
        case .wait: break
        }
    }

    func cancel() async {
        let already = state.withLock { s -> Bool in
            let was = s.cancelled
            s.cancelled = true
            return was
        }
        guard !already else { return }
        // The flag is up BEFORE the stop is enqueued, so a decode still
        // running sees it at its next step and returns false, and any
        // hand-off already queued finds it and stays silent.
        mouth.async { [self] in
            player.stop()
            player.reset()
        }
        out.finish()          // no terminal: the seam's cancel contract
    }

    // MARK: - decode, then render

    private func speak(_ text: String) async {
        do {
            _ = try await kit.generate(
                text: text, voice: nil, language: nil, options: GenerationOptions()
            ) { [weak self] progress in
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
                if NeuralVoiceRun.traceSteps {
                    let now = ContinuousClock().now
                    let since = self.stepClock.withLock { last -> Duration in
                        let d = (last ?? self.birth).duration(to: now)
                        last = now
                        return d
                    }
                    let ms = Double(since.components.seconds) * 1000
                        + Double(since.components.attoseconds) * 1e-15
                    _ = ms
                    self.stepTotals.withLock { $0.samples += progress.audio.count }
                }
                self.render(progress.audio)
                return true
            }
        } catch {
            let live = state.withLock { !$0.cancelled }
            if live { report(.failed("neural voice: \(error)"), terminal: true) }
        }
        let done = state.withLock { s -> Bool in
            s.phrasesInFlight -= 1
            return !s.cancelled && s.tokensFinished
                && s.phrasesInFlight == 0 && s.scheduled == s.played
        }
        if done { report(.finished, terminal: true) }
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
            player.scheduleBuffer(buffer) { [weak self] in
                self?.bufferPlayed()
            }
            // AUDIBLE means scheduled onto a running player, which is the
            // closest honest moment we have to "sound is in the room"
            // (D-045 F-2: not when generation started — nothing can be
            // heard then).
            let first = state.withLock { s -> Bool in
                guard !s.cancelled, !s.startedReported else { return false }
                s.startedReported = true
                return true
            }
            if first { report(.started, terminal: false) }
        }
    }

    private func bufferPlayed() {
        let done = state.withLock { s -> Bool in
            s.played += 1
            return !s.cancelled && s.tokensFinished
                && s.phrasesInFlight == 0 && s.scheduled == s.played
        }
        if done { report(.finished, terminal: true) }
    }

    private func report(_ update: SynthesisUpdate, terminal: Bool) {
        if terminal { reportMargin() }
        out.yield(update)
        if terminal { out.finish() }
    }
}
