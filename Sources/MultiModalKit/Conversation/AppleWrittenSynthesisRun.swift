import AVFAudio
import Dispatch
import Foundation
import Synchronization

/// APPLE'S MOUTH, RENDERED WHERE THE CANCELLER CAN SEE IT (4g, AC-121,
/// D-060 F-2 = A).
///
/// The delegate run hands text to `AVSpeechSynthesizer` and the OS plays
/// it on a private route — which is why D-043 measured the reply reaching
/// the microphone at full scale with the canceller demonstrably working
/// on everything else: iOS removes only what its OWN unit renders, and
/// Apple's mouth rendered elsewhere.
///
/// This run takes the other road the same API offers:
/// `write(_:toBufferCallback:)` hands us the PCM instead of playing it,
/// and we schedule it on a `PlaybackHost` — the same seam the neural
/// mouth renders through, so behind the shield BOTH mouths sit on the
/// capture engine and the canceller sees them all. One rendering path
/// for every mouth, which was the whole of the F-2 ruling.
///
/// The shape is `NeuralVoiceRun`'s, deliberately — that file's doctrine
/// was paid for twice (the 4e review's abort, D-055's funnel):
/// - all state behind ONE `Mutex`, nothing suspends under it, no
///   continuation resumed under it, every player touch on one serial
///   queue;
/// - every terminal path through one `retire()` latch;
/// - "is this reply complete, and what does it owe?" answered by ONE
///   funnel, because three sites answering it is how 4e grew a hole.
///
/// **The write-path facts this depends on, and where they came from:**
/// buffers arrive on the framework's own thread; a buffer with
/// `frameLength == 0` marks the utterance's end; the format is the
/// VOICE's (not ours to choose) and is read off the first real buffer,
/// which is when the player attaches. Verified against the live kit —
/// not assumed from documentation.
final class AppleWrittenSynthesisRun: NSObject, SynthesisRun, @unchecked Sendable {
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let host: any PlaybackHost
    private let player = AVAudioPlayerNode()
    /// The framework object's ONE thread — FIFO matters (a stop enqueued
    /// after a hand-off must run after it), so a serial queue, not an
    /// actor.
    private let mouth = DispatchQueue(label: "dev.nooron.MultiModalKit.writtenMouth")

    private struct Guarded {
        var phraser = SpeechPhraser()
        var pending: [String] = []
        var draining = false
        var phrasesInFlight = 0
        var scheduled = 0
        var played = 0
        var startedReported = false
        var attached = false
        var tokensFinished = false
        var retired = false
    }
    private let state: Mutex<Guarded>
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(voiceIdentifier: String?, host: any PlaybackHost) {
        var handle: AsyncStream<SynthesisUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        self.host = host
        self.state = Mutex(Guarded())
        super.init()
    }

    // MARK: - the seam (hands off, the conformance promise)

    func feed(_ token: String) async {
        let startDrain = state.withLock { s -> Bool in
            guard !s.retired else { return false }
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

    func finishTokens() async {
        enum Outcome { case startDrain, settle(Owed) }
        let outcome = state.withLock { s -> Outcome in
            guard !s.retired, !s.tokensFinished else { return .settle(.nothing) }
            s.tokensFinished = true
            if let rest = s.phraser.flush() {
                s.phrasesInFlight += 1
                s.pending.append(rest)
                guard !s.draining else { return .settle(.nothing) }
                s.draining = true
                return .startDrain
            }
            return .settle(Self.owed(by: s))
        }
        switch outcome {
        case .startDrain: beginDraining()
        case .settle(let owed): settle(owed)
        }
    }

    func cancel() async {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            s.pending.removeAll()
            return !was
        }
        work.withLock { $0 }?.cancel()
        mouth.async { [self] in
            synthesizer.stopSpeaking(at: .immediate)
            player.stop()
            player.reset()
            host.detachFromPlayback(player)
        }
        guard first else { return }
        out.finish()
    }

    // MARK: - the funnel (the D-055 lesson, applied at birth)

    private enum Owed { case nothing, finish }

    /// ONE answer to "is this reply complete?" — no lead exists here
    /// (Apple's synthesis outruns real time on every measured device),
    /// so the only debts are the terminal or nothing.
    private static func owed(by s: Guarded) -> Owed {
        guard !s.retired, s.tokensFinished, s.phrasesInFlight == 0,
              s.scheduled == s.played else { return .nothing }
        return .finish
    }

    private func settle(_ owed: Owed) {
        guard case .finish = owed else { return }
        report(.finished)
    }

    /// Every terminal path ends here; only the first acts (the retire
    /// doctrine, adopted rather than retrofitted).
    private func report(_ terminal: SynthesisUpdate) {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            return !was
        }
        guard first else { return }
        out.yield(terminal)
        out.finish()
        mouth.async { [self] in
            player.stop()
            host.detachFromPlayback(player)
        }
    }

    // MARK: - write → schedule → count

    private func beginDraining() {
        let task = Task { [self] in
            while true {
                let next = state.withLock { s -> String? in
                    guard !s.retired, !s.pending.isEmpty else {
                        s.draining = false
                        return nil
                    }
                    return s.pending.removeFirst()
                }
                guard let next else { return }
                await write(next)
            }
        }
        work.withLock { $0 = task }
    }

    private func write(_ text: String) async {
        // The unspeakable guard, the neural mouth's lesson: a phrase with
        // nothing to say must still be ACCOUNTED for, never synthesized.
        if SpeechPhraser.hasSpeakableContent(text) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let utterance = AVSpeechUtterance(string: text)
                if let voice { utterance.voice = voice }
                let finished = Mutex(false)
                // Handed across ONCE, never touched again by this thread.
                let handed = WrittenHandOff(utterance)
                mouth.async { [self] in
                    synthesizer.write(handed.value) { [weak self] buffer in
                        guard let self else { return }
                        // frameLength == 0 is the utterance's END marker —
                        // resuming exactly once is guarded, because the
                        // callback's threading is the framework's business,
                        // not a promise.
                        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                            if !finished.withLock({ let was = $0; $0 = true; return was }) {
                                done.resume()
                            }
                            return
                        }
                        self.render(pcm)
                    }
                }
            }
        }

        let owed = state.withLock { s -> Owed in
            s.phrasesInFlight -= 1
            return Self.owed(by: s)
        }
        settle(owed)
    }

    /// One written buffer onto the host — attach lazily at the VOICE's
    /// format, which is only knowable from the first real buffer.
    private func render(_ buffer: AVAudioPCMBuffer) {
        let mayRender = state.withLock { s -> Bool in
            guard !s.retired else { return false }
            s.scheduled += 1
            return true
        }
        guard mayRender else { return }

        // The buffer arrives on the framework's write thread and is handed
        // to the mouth queue ONCE; nobody on the sending side keeps it.
        let handed = WrittenHandOff(buffer)
        mouth.async { [self] in
            // EVERY early return balances the count, or `finished` never
            // fires — the liveness law the counting exists to keep.
            guard state.withLock({ !$0.retired }) else { return bufferPlayed() }
            let needsAttach = state.withLock { s -> Bool in
                guard !s.attached else { return false }
                s.attached = true
                return true
            }
            if needsAttach {
                do { try host.attachForPlayback(player, format: handed.value.format) }
                catch {
                    state.withLock { $0.attached = false }
                    bufferPlayed()
                    report(.failed("the host refused the written reply: \(error)"))
                    return
                }
            }
            player.scheduleBuffer(handed.value, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.bufferPlayed()
            }
            let start = state.withLock { s -> Bool in
                guard !s.retired, !s.startedReported else { return false }
                s.startedReported = true
                return true
            }
            if start {
                player.play()
                out.yield(.started)
            }
        }
    }

    private func bufferPlayed() {
        let owed = state.withLock { s -> Owed in
            s.played += 1
            return Self.owed(by: s)
        }
        settle(owed)
    }
}

/// The `AppleSpeechEngine` precedent, verbatim in spirit: the SDK's
/// closures are `@Sendable`, these objects are not — and in BOTH uses the
/// object is created on one thread, handed across exactly once, and never
/// touched by the sender again. The box makes that written-down fact
/// visible to the compiler instead of silencing it with `@preconcurrency`.
private final class WrittenHandOff<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
