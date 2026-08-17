import AVFAudio
import Foundation
import MultiModalKit
import Synchronization

/// ONE spoken reply from the neural voice (SPEC AC-101, D-045).
///
/// The shape deliberately mirrors `AppleSynthesisRun`, because that one
/// is proven: a `SpeechPhraser` upstream, evidence-based updates, and a
/// queued/finished count deciding when the room is quiet. What differs
/// is who renders — and that difference is the milestone's second prize.
///
/// **We render, the decoder only decodes (D-045 F-1 = B).** A decode step
/// hands back ~80 ms of PCM; those samples are scheduled on a player node
/// on an `AVAudioEngine` we control. D-043 measured that iOS voice
/// processing cancels only what its OWN audio unit renders, so a reply
/// rendered here is the first one the canceller can possibly see. The
/// cost, accepted in the ruling: pre-buffering and resampling become
/// ours to get wrong.
///
/// **And the decoder is a SEAM, not a vendor (AC-109, D-053 F-6).** This
/// file named `TTSKit` until the 4e review found that a failed decode
/// aborted the process and the fix could not be tested — nothing can make
/// a real 1.1 GB model fail on command. It holds `any TTSDecoding` now, so
/// a scripted decoder makes decodes throw and block, and the guarantees
/// below are pinned rather than argued.
///
/// `@unchecked Sendable`, with the same proof shape as the Apple mouth:
/// all mutable state lives behind one `Mutex`, nothing suspends under
/// it, no continuation is resumed while it is held, and every touch of
/// the engine happens on one serial queue.
final class NeuralVoiceRun: SynthesisRun, @unchecked Sendable {
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation

    private let decoder: any TTSDecoding
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
        /// Phrases accepted but not yet decoded. THE POINT OF THIS
        /// QUEUE is that `feed` can put a phrase here and return, rather
        /// than standing still until a model finishes speaking it.
        var pending: [String] = []
        /// Whether a decoder is already working through `pending`. One
        /// at a time, because a reply's phrases must be spoken in order.
        var draining = false
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
    /// The owned worker. Held so `cancel()` can stop it.
    private let drainTask = Mutex<Task<Void, Never>?>(nil)

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
        // The HANDLER is not gated by the trace flag: a phone has no
        // stderr to read, and the phone is where this number is now
        // needed. The printing stays opt-in; the reporting does not.
        guard NeuralVoiceRun.traceSteps || onMargin != nil else { return }
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
                let prefill = ms(birth.duration(to: first))
                let steady = steadyWall / steadyAudio
                line += String(format: " . prefill %.0f ms . STEADY %.3f", prefill, steady)
                onMargin?(DecodeMargin(audioMilliseconds: audio,
                                       wallMilliseconds: wall,
                                       prefillMilliseconds: prefill,
                                       steadyRealTimeFactor: steady))
            }
        }
        if NeuralVoiceRun.traceSteps {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    private let temperature: Float?
    private let onMargin: (@Sendable (DecodeMargin) -> Void)?

    /// The sample rate comes from the DECODER, not from a parameter beside
    /// it. It used to be passed in — always as `Double(kit.sampleRate)`,
    /// from the one call site — which left two ways to state one fact.
    /// Since the format built below is what the samples are played at, two
    /// ways to state it is exactly how a 24 kHz voice ends up played as
    /// 16 kHz, which is the "drunk" voice the field reported.
    init(decoder: any TTSDecoding, host: any PlaybackHost,
         lead: PlaybackLead, temperature: Float? = nil,
         onMargin: (@Sendable (DecodeMargin) -> Void)? = nil) throws {
        self.onMargin = onMargin
        self.state = Mutex(Guarded(lead: lead))
        self.temperature = temperature
        self.decoder = decoder
        self.host = host
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(decoder.sampleRate),
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

    /// HANDS OFF. DOES NOT DECODE. (Conformance promise 6.)
    ///
    /// This used to `await speak(phrase)` — a full model decode, seconds
    /// long — and the coordinator awaits its handlers inline, on one
    /// serial loop, by design. So the user's speech onset, the very
    /// event meant to cancel this reply, queued behind the decode of the
    /// reply it was trying to stop. The field reported it as "barge in
    /// to late" before any test could: every barge test in the suite
    /// runs against a scripted mouth whose `feed` cannot block.
    ///
    /// Apple's mouth never had the fault, and its shape is copied here:
    /// take the text, put it somewhere, return. The work happens
    /// elsewhere.
    func feed(_ token: String) async {
        let startDrain = state.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            let completed = s.phraser.feed(token)
            guard !completed.isEmpty else { return false }
            s.phrasesInFlight += completed.count
            s.pending.append(contentsOf: completed)
            guard !s.draining else { return false }
            s.draining = true
            return true
        }
        if startDrain { beginDraining() }
    }

    /// Also hands off, for the same reason — and it matters MORE here
    /// than in `feed`. The phraser only cuts at clause marks, so a reply
    /// with no punctuation in its body flushes as ONE phrase at the end:
    /// the single longest decode of the turn, covering nearly all of the
    /// audible reply, which is exactly the window a human interrupts in.
    func finishTokens() async {
        enum Outcome { case startDrain, finishNow, wait }
        let outcome = state.withLock { s -> Outcome in
            guard !s.cancelled, !s.tokensFinished else { return .wait }
            s.tokensFinished = true
            if let rest = s.phraser.flush() {
                s.phrasesInFlight += 1
                s.pending.append(rest)
                guard !s.draining else { return .wait }
                s.draining = true
                return .startDrain
            }
            // Nothing left to say, and nothing still sounding: a reply of
            // pure whitespace ends here, silently.
            return (s.phrasesInFlight == 0 && s.scheduled == s.played) ? .finishNow : .wait
        }
        switch outcome {
        case .startDrain: beginDraining()
        case .finishNow: report(.finished, terminal: true)
        case .wait: break
        }
    }

    /// The one worker that turns queued phrases into sound, in order.
    ///
    /// An unstructured `Task`, which this project's rules allow only
    /// when it is OWNED rather than leaked — so it is: stored, cancelled
    /// in `cancel()`, and it ends on its own the moment the queue is
    /// empty. Its lifetime cannot outlive the reply, because the reply
    /// is the only thing that fills the queue.
    ///
    /// Cancelling it is an OPTIMISATION, not the guarantee. The
    /// guarantee is the `cancelled` flag, which the decode callback
    /// checks at every step and which every path here re-reads — the
    /// same doctrine the coordinator uses for its ticket.
    private func beginDraining() {
        let task = Task { [self] in
            while true {
                let next = state.withLock { s -> String? in
                    guard !s.cancelled, !s.pending.isEmpty else {
                        s.draining = false
                        return nil
                    }
                    return s.pending.removeFirst()
                }
                guard let next else { return }
                await speak(next)
            }
        }
        drainTask.withLock { $0 = task }
    }

    /// THE RUN IS OVER — latch it, in ONE locked step.
    ///
    /// Every terminal path ends here, and that is a correction the 4e
    /// review forced. Only `cancel()` used to raise this flag, so a
    /// `.failed` decode reported its terminal, handed the player node
    /// back to the engine in `teardown()`, and then **kept going**: the
    /// drain loop re-reads only `cancelled`, so it popped the next
    /// phrase, decoded it, and called `play()` / `scheduleBuffer` on a
    /// node with no engine. AVFoundation does not throw there — it
    /// aborts the process.
    ///
    /// It also broke this repo's own doctrine, written twenty lines
    /// above: a run that has reported a terminal must not act again, and
    /// the flag is the guarantee. Cancelling the drain task is the
    /// optimisation.
    ///
    /// - Returns: true if this call is the one that retired the run.
    @discardableResult
    private func retire() -> Bool {
        let already = state.withLock { s -> Bool in
            let was = s.cancelled
            s.cancelled = true
            s.lead.abandon()      // same step, no gap: the ticket doctrine
            s.pending.removeAll() // nothing queued will ever be spoken
            return was
        }
        guard !already else { return false }
        drainTask.withLock { $0 }?.cancel()
        return true
    }

    func cancel() async {
        // `retire` raises the flag, empties the queue and stops the
        // worker, and reports whether THIS call was the one that did it.
        // A second cancel — or a cancel after the run already reported a
        // terminal — has nothing left to do.
        guard retire() else { return }
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
