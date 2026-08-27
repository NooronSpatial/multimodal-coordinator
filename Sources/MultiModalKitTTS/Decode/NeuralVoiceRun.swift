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
    let out: AsyncStream<SynthesisUpdate>.Continuation

    let decoder: any TTSDecoding
    let host: any PlaybackHost
    let player = AVAudioPlayerNode()
    let format: AVAudioFormat
    /// The engine's one thread. Same reasoning as the Apple mouth: FIFO
    /// matters, and Swift actors make no ordering promise between two
    /// independent callers.
    let mouth = DispatchQueue(label: "dev.nooron.MultiModalKit.neuralMouth")

    struct Guarded {
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
    let state: Mutex<Guarded>
    /// Step tracing, opt-in through the environment so it costs nothing
    /// when nobody is asking.
    static let traceSteps = ProcessInfo.processInfo.environment["MMK_TRACE_TTS"] == "1"
    let stepClock = Mutex<ContinuousClock.Instant?>(nil)

    /// WHERE TIME COMES FROM (4o, AC-174).
    ///
    /// A time SOURCE, not a `Clock`, and the difference is the whole
    /// reason this is a closure rather than a generic parameter: this
    /// type only ever READS the clock — it stamps an instant and
    /// subtracts. It never sleeps, never schedules, never waits on a
    /// deadline. `AudioPump` is generic over `Clock` because it genuinely
    /// suspends until the next poll; making this type generic would push
    /// a type parameter through `NeuralVoice` for a capability nobody
    /// calls.
    ///
    /// Injected because the determinism law says so and because AC-174's
    /// record is now load-bearing: the step's WALL TIME is what sizes the
    /// cushion (D-080), and a field pinned by nothing is the kind of
    /// instrument §53 caught lying.
    let now: @Sendable () -> ContinuousClock.Instant
    let birth: ContinuousClock.Instant
    struct Totals {
        var samples = 0
        var firstStep: ContinuousClock.Instant?
        var firstSamples = 0
        /// THE RECORD THAT DID NOT EXIST (4o, AC-174). One entry per
        /// decode step: what it cost and what it produced.
        ///
        /// This callback already stamped a clock and already counted
        /// samples — it simply threw the INTERVAL away, keeping only
        /// totals. That is why four milestones could see an average and
        /// never a stall, and why D-046's rule survived being wrong
        /// (D-080).
        ///
        /// Kept whole rather than folded into a running maximum on
        /// purpose: `DecodeDeficit.worstLag` is a pure function over a
        /// sequence, so it can be tested with no decoder, no clock and no
        /// audio — and a sequence can answer questions a running maximum
        /// has already forgotten, which the sweep of AC-178 will need.
        /// The cost is bounded and small: a 30-second reply at ~20 ms per
        /// step is about 1500 entries of two Doubles.
        var steps: [DecodeStep] = []
    }
    let stepTotals = Mutex(Totals())
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
    /// The cushion this run was BUILT with — what was really in force,
    /// kept for the margin because asking the voice afterwards returns
    /// the value the learner just adapted to (the 4n review's blocker).
    let leadInForce: Duration

    let temperature: Float?
    let onMargin: (@Sendable (DecodeMargin) -> Void)?

    /// The sample rate comes from the DECODER, not from a parameter beside
    /// it. It used to be passed in — always as `Double(kit.sampleRate)`,
    /// from the one call site — which left two ways to state one fact.
    /// Since the format built below is what the samples are played at, two
    /// ways to state it is exactly how a 24 kHz voice ends up played as
    /// 16 kHz, which is the "drunk" voice the field reported.
    init(decoder: any TTSDecoding, host: any PlaybackHost,
         lead: PlaybackLead, temperature: Float? = nil,
         onMargin: (@Sendable (DecodeMargin) -> Void)? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant
            = { ContinuousClock().now }) throws {
        self.now = now
        self.birth = now()
        self.onMargin = onMargin
        self.state = Mutex(Guarded(lead: lead))
        self.leadInForce = lead.target
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

    // MARK: - the funnel: what a complete reply owes (D-055 = B)

    /// What the reply owes right now — **asked in ONE place.**
    enum Owed {
        /// Not complete, or already dead. Nothing to do.
        case nothing
        /// Everything queued has been HEARD. Report the terminal.
        case finish
        /// Everything that will ever be queued IS queued, and the lead's
        /// target will never be reached. Release it, or nothing ever plays.
        case releaseLead
    }

    /// THE SINGLE ANSWER. Pure, and computed under the caller's lock.
    ///
    /// Three places can learn that a reply became complete — the last
    /// decode finishing (`speak`), the token stream closing
    /// (`finishTokens`), and the last buffer being heard (`bufferPlayed`)
    /// — and ANY of them may be the last to arrive. Before D-055 each
    /// asked its own version of the question and one of them asked a
    /// smaller one: `finishTokens` could only report a finish, never
    /// release a lead. So a reply whose tokens closed AFTER its final
    /// decode was stranded — fully decoded, never started, `.finished`
    /// never fired, the turn hung (INSTRUMENTS §21).
    ///
    /// D-055 = B: not "add the missing arm" but "stop having three sites
    /// answer one question", which is the funnel doctrine this repo
    /// already applies to every state write in `TranscriptionSession` and
    /// `TurnCoordinator`. A fourth caller cannot half-apply an invariant
    /// that lives in one function.
    static func owed(by guarded: Guarded) -> Owed {
        guard !guarded.cancelled, guarded.tokensFinished, guarded.phrasesInFlight == 0
        else { return .nothing }
        return guarded.scheduled == guarded.played ? .finish : .releaseLead
    }

    /// Acts on the funnel's answer. **Never called while the lock is
    /// held** — `report` finishes a stream and `releaseLead` touches the
    /// player, and this file's whole safety proof is that nothing
    /// suspends or reaches hardware under the mutex.
    func settle(_ owed: Owed) {
        switch owed {
        case .nothing: break
        case .finish: report(.finished, terminal: true)
        case .releaseLead: mouth.async { [self] in releaseLead() }
        }
    }

    /// The four counters, carried by name rather than by position.
    struct Counters {
        let phrasesInFlight: Int
        let scheduled: Int
        let played: Int
        let tokensFinished: Bool
    }

    /// A SNAPSHOT OF THE COUNTERS, for tests that must gate on an ordering
    /// rather than guess at it.
    ///
    /// `PlaybackLeadStrandTests` (D-055) needs to act at one exact moment:
    /// after the last phrase's decode has been ACCOUNTED FOR — its
    /// `phrasesInFlight` decrement is what proves the liveness step already
    /// ran — and before the token stream closes. Waiting on the decoder
    /// instead was a race, and it flaked 3 times in 20: the decoder reports
    /// done from INSIDE `decode`, so `finishTokens()` could arrive before
    /// the accounting, where `speak()`'s own `.release` arm correctly saves
    /// the reply and the hole never opens.
    ///
    /// Internal, like the type, so it widens no public surface — the same
    /// bargain as `AudioEnginePlaybackHost.hostedCount`.
    var counters: Counters {
        state.withLock {
            Counters(phrasesInFlight: $0.phrasesInFlight, scheduled: $0.scheduled,
                     played: $0.played, tokensFinished: $0.tokensFinished)
        }
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
        let startDrain = state.withLock { guarded -> Bool in
            guard !guarded.cancelled else { return false }
            let completed = guarded.phraser.feed(token)
            guard !completed.isEmpty else { return false }
            guarded.phrasesInFlight += completed.count
            guarded.pending.append(contentsOf: completed)
            guard !guarded.draining else { return false }
            guarded.draining = true
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
        enum Outcome { case startDrain, settle(Owed) }
        let outcome = state.withLock { guarded -> Outcome in
            guard !guarded.cancelled, !guarded.tokensFinished else { return .settle(.nothing) }
            guarded.tokensFinished = true
            if let rest = guarded.phraser.flush() {
                guarded.phrasesInFlight += 1
                guarded.pending.append(rest)
                guard !guarded.draining else { return .settle(.nothing) }
                guarded.draining = true
                return .startDrain
            }
            // THROUGH THE FUNNEL (D-055 = B). This used to ask a smaller
            // question — "may I report finished?" — and answer `.wait` to
            // everything else. But closing the token stream is one of the
            // three ways a reply becomes complete, and when it is the LAST
            // of them to arrive it must be able to release a lead that can
            // no longer be reached. It could not, so the reply was
            // stranded: decoded, silent, and never finishing.
            //
            // A reply of pure whitespace still ends here silently — the
            // funnel returns `.finish` for it, because nothing was queued
            // and so `scheduled == played`.
            return .settle(Self.owed(by: guarded))
        }
        switch outcome {
        case .startDrain: beginDraining()
        case .settle(let owed): settle(owed)
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
                let next = state.withLock { guarded -> String? in
                    guard !guarded.cancelled, !guarded.pending.isEmpty else {
                        guarded.draining = false
                        return nil
                    }
                    return guarded.pending.removeFirst()
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
    func retire() -> Bool {
        let already = state.withLock { guarded -> Bool in
            let was = guarded.cancelled
            guarded.cancelled = true
            guarded.lead.abandon()      // same step, no gap: the ticket doctrine
            guarded.pending.removeAll() // nothing queued will ever be spoken
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
}
