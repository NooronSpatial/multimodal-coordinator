import AVFAudio
import Synchronization

/// The first real mouth (SPEC AC-80, D-037): `AVSpeechSynthesizer` behind
/// the `SpeechSynthesizing` seam. THIN on purpose — the token→phrase
/// intelligence lives in `SpeechPhraser` (tested exactly); this file only
/// wires phrases to the OS and maps the delegate's evidence onto the
/// seam's updates. It joins `AppleSpeechEngine` on the recorded
/// un-TDD-able list: what touches real audio is verified live (the
/// conformance kit's gated suite + the demo), never simulated.
///
/// Evidence, not intent (D-029, F-4 = A):
/// - `.started`  = the FIRST utterance's `didStart` — sound is audible.
/// - `.finished` = the LAST queued utterance's `didFinish`, and only
///   after `finishTokens()` — the reply is done when the room is quiet,
///   not when the generator stopped typing.
/// - `cancel()`  = `stopSpeaking(.immediate)`, stream ends, NO terminal
///   (the seam's cancel contract).
public final class AppleSpeechSynthesizer: SpeechSynthesizing {
    /// A specific voice identifier, or nil for the system default.
    private let voiceIdentifier: String?

    public init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
    }

    public func openUtterance() async throws -> any SynthesisRun {
        AppleSynthesisRun(voiceIdentifier: voiceIdentifier)
    }
}

/// One spoken reply. `@unchecked Sendable` — the documented island, with
/// the proof (§4.1): every caller-facing method (`feed`, `finishTokens`,
/// `cancel`) is invoked from the coordinator's actor, so the
/// `AVSpeechSynthesizer` object itself is touched from ONE serialized
/// context only; the delegate callbacks arrive on the framework's thread
/// and touch nothing but the `Mutex` state and the continuation (which is
/// thread-safe). Lock rules kept: nothing suspends under the lock, and
/// every yield happens on a snapshot taken inside it, after it releases.
final class AppleSynthesisRun: NSObject, SynthesisRun, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    private struct Guarded {
        var phraser = SpeechPhraser()
        var queued = 0            // utterances handed to the OS
        var finished = 0          // utterances the OS reported done
        var startedReported = false
        var tokensFinished = false
        var cancelled = false
    }
    private let state = Mutex(Guarded())

    init(voiceIdentifier: String?) {
        var handle: AsyncStream<SynthesisUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        super.init()
        synthesizer.delegate = self
    }

    func feed(_ token: String) async {
        let phrases = state.withLock { s -> [String] in
            guard !s.cancelled else { return [] }
            let completed = s.phraser.feed(token)
            s.queued += completed.count
            return completed
        }
        // THE REENTRANCY LAW, one level down. The coordinator calls this
        // with `await`, so the actor may service a BARGE while we are
        // suspended here — and a barge cancels this run. Handing the OS a
        // phrase after that would put the dead turn's voice in the room:
        // the ticket doctrine's forbidden artifact, in its audible form.
        // So the flag is re-read before every phrase, and once more after
        // (the window between check and hand-off is closed by stopping
        // what we just queued — cancel() sets the flag BEFORE it stops,
        // so whichever order the two land in, silence wins).
        for phrase in phrases {
            let live = state.withLock { !$0.cancelled }
            guard live else { return }
            speak(phrase)
            if state.withLock({ $0.cancelled }) {
                synthesizer.stopSpeaking(at: .immediate)
                return
            }
        }
    }

    func finishTokens() async {
        // Same law, same reason: this is awaited too, so a barge may have
        // landed while we waited to run.
        enum Outcome { case speak(String), finishNow, wait }
        let outcome = state.withLock { s -> Outcome in
            guard !s.cancelled, !s.tokensFinished else { return .wait }
            s.tokensFinished = true
            if let rest = s.phraser.flush() {
                s.queued += 1
                return .speak(rest)
            }
            // Nothing left to say. If nothing is still sounding, the reply
            // is over NOW — a whitespace-only reply completes silently.
            return s.finished == s.queued ? .finishNow : .wait
        }
        switch outcome {
        case .speak(let rest):
            speak(rest)
        case .finishNow:
            out.yield(.finished)
            out.finish()
        case .wait:
            break                                      // the last didFinish decides
        }
    }

    func cancel() async {
        let alreadyCancelled = state.withLock { s -> Bool in
            let was = s.cancelled
            s.cancelled = true
            return was
        }
        guard !alreadyCancelled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        out.finish()                                   // no terminal: the contract
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    // MARK: - the delegate: evidence in, updates out

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        let fire = state.withLock { s -> Bool in
            guard !s.cancelled, !s.startedReported else { return false }
            s.startedReported = true
            return true
        }
        if fire { out.yield(.started) }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let done = state.withLock { s -> Bool in
            s.finished += 1
            return !s.cancelled && s.tokensFinished && s.finished == s.queued
        }
        if done {
            out.yield(.finished)
            out.finish()
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        // `cancel()` already finished the stream; a late yield on a
        // finished continuation is a no-op. Nothing to do — recorded so
        // the reader knows the silence is deliberate.
    }
}
