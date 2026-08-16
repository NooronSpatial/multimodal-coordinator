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
    private let host: any PlaybackHost
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
        var lead: PlaybackLead
        var tokensFinished = false
        var cancelled = false
    }
    private let state: Mutex<Guarded>
    /// Step tracing, opt-in through the environment so it costs nothing
    /// when nobody is asking.
    static let traceSteps = ProcessInfo.processInfo.environment["MMK_TRACE_TTS"] == "1"
    private let stepClock = Mutex<ContinuousClock.Instant?>(nil)
    private let birth = ContinuousClock().now
    private struct Totals {
        var samples = 0
        var firstStep: ContinuousClock.Instant?
        var firstSamples = 0
    }
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
    /// ONE NUMBER WAS HIDING TWO COSTS (AC-106). This clocked from the
    /// run's BIRTH, so every reported factor carried a fixed ~230 ms of
    /// prefill — the model's first step, paid once. Divide that fixed
    /// cost by three different audio lengths and you get three different
    /// factors for one decoder: AC-102's spread of 1.09-1.23 was mostly
    /// the SHORTEST sentence failing to amortise it, not a decoder that
    /// changes speed.
    ///
    /// That mattered twice over. It made the sizing rule use 1.25 when
    /// the steady rate is nearer 1.08 — an oversized lead, paid in felt
    /// pause — and it would have graded every speed lever wrongly, since
    /// a lever that saves a real 8 ms per frame shows up as 0.06 on one
    /// row and 0.03 on another. So the two are separated: prefill is
    /// reported as itself, and STEADY RTF is measured from the first
    /// step onward, which is the only rate a decode lever can move.
    private func reportMargin() {
        guard NeuralVoiceRun.traceSteps else { return }
        let (samples, firstStep, firstSamples) = stepTotals.withLock {
            ($0.samples, $0.firstStep, $0.firstSamples)
        }
        guard samples > 0, let last = stepClock.withLock({ $0 }) else { return }
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
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
                line += String(format: " . prefill %.0f ms . STEADY %.3f",
                               ms(birth.duration(to: first)), steadyWall / steadyAudio)
            }
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private let temperature: Float?

    init(kit: TTSKit, host: any PlaybackHost, sampleRate: Double,
         lead: PlaybackLead, temperature: Float? = nil) throws {
        self.state = Mutex(Guarded(lead: lead))
        self.temperature = temperature
        self.kit = kit
        self.host = host
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw TurnFailure.synthesisFailed("the neural voice's format was refused")
        }
        self.format = format

        var handle: AsyncStream<SynthesisUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle

        // The host owns the ORDER — attach, connect, then start — and
        // throws rather than silently attaching to a graph nobody pulls
        // (AC-108). That failure used to be ours to get wrong, and we
        // did: an engine started before any node existed hung a
        // measurement run for twenty minutes (INSTRUMENTS §14).
        try host.attachForPlayback(player, format: format)
        // NOT `player.play()` — that was the bug AC-102 measured. The
        // player starts when `PlaybackLead` says a cushion exists, and
        // not one buffer sooner (D-046 = A).
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
            s.lead.abandon()      // same step, no gap: the ticket doctrine
            return was
        }
        guard !already else { return }
        // The flag is up BEFORE the stop is enqueued, so a decode still
        // running sees it at its next step and returns false, and any
        // hand-off already queued finds it and stays silent.
        mouth.async { [self] in
            player.stop()
            player.reset()
            host.detachFromPlayback(player)
        }
        out.finish()          // no terminal: the seam's cancel contract
    }

    // MARK: - decode, then render

    private func speak(_ text: String) async {
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
                var options = GenerationOptions()
                // NOT A TUNING KNOB - A CORRECTNESS PIN, and TTSKit proves it
                // by doing the same thing in its own `play()`.
                //
                // The default is 0, "all chunks run concurrently in one
                // batch". On that path the streaming callback is handed
                // `audio: []` on every single step, and the real samples
                // arrive only after the WHOLE batch finishes decoding
                // (TTSKit.swift:910-919 and :958-972). A renderer like ours
                // would receive nothing to play until the entire reply was
                // decoded - no streaming, no lead, first-audio back to full
                // decode time - and it would happen silently, only for
                // replies long enough to split into two chunks. Every
                // sentence measured so far is one chunk, which is exactly
                // why this never showed.
                //
                // `1` takes the sequential branch, which passes the real
                // callback through untouched (TTSKit.swift:858-880). The
                // library's own real-time path sets the same value for the
                // same reason (TTSKit.swift:1046).
                options.concurrentWorkerCount = 1
                if let temperature { options.temperature = temperature }
                _ = try await kit.generate(
                    text: text, voice: nil, language: nil, options: options
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
                        self.stepTotals.withLock {
                            if $0.firstStep == nil {
                                $0.firstStep = now
                                $0.firstSamples = progress.audio.count
                            }
                            $0.samples += progress.audio.count
                        }
                    }
                    self.render(progress.audio)
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
        enum After { case finish, release, nothing }
        let after = state.withLock { s -> After in
            s.phrasesInFlight -= 1
            guard !s.cancelled, s.tokensFinished, s.phrasesInFlight == 0
            else { return .nothing }
            return s.scheduled == s.played ? .finish : .release
        }
        switch after {
        case .finish: report(.finished, terminal: true)
        case .release: mouth.async { [self] in releaseLead() }
        case .nothing: break
        }
    }

    /// The reply is complete: whatever is held is all there will ever be.
    /// Runs on the mouth queue, like every other touch of the player.
    private func releaseLead() {
        let start = state.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            return s.lead.noMoreAudio()
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
                                  completionCallbackType: .dataPlayedBack) {
                [weak self] _ in
                self?.bufferPlayed()
            }
            // AUDIBLE now means THE PLAYER WAS STARTED, which is a
            // stricter reading of D-045 F-2 than the one this file
            // shipped with: scheduling a buffer onto a node that is not
            // playing puts no sound in the room. `PlaybackLead` owns the
            // once-only guarantee, so there is no separate flag to keep
            // honest.
            let start = state.withLock { s -> Bool in
                guard !s.cancelled else { return false }
                return s.lead.queue(.microseconds(
                    Int((Double(samples.count) / format.sampleRate * 1_000_000).rounded())))
            }
            if start {
                player.play()
                report(.started, terminal: false)
            }
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
        if terminal { out.finish(); teardown() }
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
