import AVFAudio
import Dispatch
import Foundation
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

    /// One installed voice, in a shape a screen can list.
    ///
    /// Exists so an app can OFFER THE CHOICE rather than have one made
    /// for it. `bestInstalledVoice` picks well, but "well" is a matter
    /// of taste and of what the person downloaded, and neither is this
    /// library's business to settle.
    public struct InstalledVoice: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let quality: String
        public let language: String
        /// `Samantha — compact, en-US`. The quality is in the label on
        /// purpose: "compact" is the honest explanation for a robotic
        /// voice, and seeing it points at a download rather than a bug.
        public var label: String { "\(name) — \(quality), \(language)" }
    }

    /// Every installed voice, best first.
    ///
    /// Sorted by quality (premium → enhanced → compact) and then by
    /// name, so the good ones are at the top of a long list. Filter by
    /// language prefix — `"en"` for every English variant, `"en-GB"` for
    /// one — or pass nil for all of them.
    public static func installedVoices(matching language: String? = nil) -> [InstalledVoice] {
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: 0
            case .enhanced: 1
            default: 2
            }
        }
        func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
            switch voice.quality {
            case .premium: "premium"
            case .enhanced: "enhanced"
            default: "compact"
            }
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard let language else { return true }
                return voice.language.hasPrefix(language)
            }
            .sorted { a, b in
                (rank(a), a.name) < (rank(b), b.name)
            }
            .map {
                InstalledVoice(id: $0.identifier, name: $0.name,
                               quality: qualityName($0), language: $0.language)
            }
    }

    /// Asks for a voice that does not sound like a robot.
    ///
    /// `nil` — what this type has always passed — means "system
    /// default", and the system default is a COMPACT voice
    /// (`com.apple.voice.compact.en-US.Samantha`). Compact is the
    /// smallest tier Apple ships and it is why the field's verdict was
    /// "like a robot". Nothing was broken; nothing better was ever
    /// requested.
    ///
    /// The tiers are `default` (compact) → `enhanced` → `premium`, and
    /// this returns the best one INSTALLED for the language.
    ///
    /// **It very often returns a compact voice anyway**, and that is not
    /// a bug in here. Enhanced and premium voices are downloads: this
    /// Mac reports 41 English voices, of which 0 are enhanced and 0 are
    /// premium. On iOS a person gets them under
    /// *Settings → Accessibility → Spoken Content → Voices*. So this
    /// function is half the answer, and the other half is on the device.
    ///
    /// Siri's own voices are NOT among these — as far as I know they
    /// are not offered to third-party apps through `AVSpeechSynthesizer`
    /// — and that is stated as belief rather than as a measurement,
    /// because nothing here has tested it.
    public static func bestInstalledVoice(
        forLanguage language: String = Locale.preferredLanguages.first ?? "en-US"
    ) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
        }
        // Exact locale first (en-GB before en-US for a British phone),
        // then quality. A worse-sounding voice in the right accent still
        // beats a better one in the wrong language.
        return candidates
            .max { a, b in
                let exactA = a.language == language ? 1 : 0
                let exactB = b.language == language ? 1 : 0
                return (exactA, rank(a)) < (exactB, rank(b))
            }
    }

    /// What `bestInstalledVoice` found, for a screen to show. A person
    /// who cannot see WHICH voice is speaking cannot tell "the app
    /// ignored my download" from "this is as good as it gets".
    public static func describe(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: "premium"
        case .enhanced: "enhanced"
        default: "compact"
        }
        return "\(voice.name) (\(quality), \(voice.language))"
    }

    public func openUtterance() async throws -> any SynthesisRun {
        AppleSynthesisRun(voiceIdentifier: voiceIdentifier)
    }
}

/// One spoken reply. `@unchecked Sendable` — the documented island, with
/// the proof (§4.1).
///
/// The FIRST version of this proof was WRONG, and an adversarial review
/// disproved it with a probe: it claimed these methods "are invoked from
/// the coordinator's actor, so the synthesizer is touched from ONE
/// serialized context only". False — `feed`/`finishTokens`/`cancel` are
/// non-isolated `async` methods, so the coordinator LEAVES the actor to
/// call them; a barge or `stop()` then enters the actor and calls
/// `cancel()` on another thread while a `feed` body is still running.
/// Two consequences, both real: a phrase handed over after the cancel
/// (the dead turn's voice in the room), and `speak`/`stopSpeaking` on a
/// non-thread-safe object from two threads at once.
///
/// The proof that now holds, by construction:
/// 1. All mutable state lives behind one `Mutex`; nothing suspends under
///    it and no continuation is resumed while it is held.
/// 2. EVERY touch of the `AVSpeechSynthesizer` happens on one serial
///    queue — so the framework object has exactly one thread, always.
/// 3. `cancel()` raises `cancelled` BEFORE it enqueues its stop, and each
///    queued hand-off re-reads that flag as its first act. So whichever
///    way the two race: either the hand-off sees the flag and stays
///    silent, or it spoke first and the stop — FIFO behind it — silences
///    it. Silence wins in every interleaving.
/// 4. Delegate callbacks touch only the `Mutex` state and the
///    continuation (itself thread-safe), never the queue — so no lock
///    ordering exists to invert.
final class AppleSynthesisRun: NSObject, SynthesisRun, AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    let updates: AsyncStream<SynthesisUpdate>
    private let out: AsyncStream<SynthesisUpdate>.Continuation
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// The framework object's ONE thread (proof point 2). FIFO matters
    /// here — a stop enqueued after a hand-off must run after it — which
    /// is why this is a serial queue and not an actor: Swift actors make
    /// no ordering promise between two independent callers.
    private let mouth = DispatchQueue(label: "dev.nooron.MultiModalKit.mouth")

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
        // The reentrancy law is enforced inside `speak`, which re-reads the
        // cancelled flag on the mouth's own queue — see proof point 3.
        for phrase in phrases { speak(phrase) }
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
        // The flag is already up (above, under the lock) BEFORE this stop
        // is enqueued — that ordering is what makes proof point 3 hold.
        mouth.async { [self] in synthesizer.stopSpeaking(at: .immediate) }
        out.finish()                                   // no terminal: the contract
    }

    /// Hands one phrase to the platform, on the mouth's own thread. The
    /// cancelled flag is re-read HERE, as the block's first act: a barge
    /// that landed while the caller was suspended has already raised it,
    /// so nothing is spoken for a turn that is already dead.
    private func speak(_ text: String) {
        // Only the TEXT crosses onto the queue: `AVSpeechUtterance` is not
        // Sendable, and building it here would smuggle a non-Sendable
        // object into a @Sendable closure (Swift 6 rejects it, and it is
        // right to — the object would then exist on two threads). It is
        // born and used entirely on the mouth's own thread instead.
        mouth.async { [self] in
            guard state.withLock({ !$0.cancelled }) else { return }
            let utterance = AVSpeechUtterance(string: text)
            if let voice { utterance.voice = voice }
            synthesizer.speak(utterance)
        }
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
