import AVFAudio
import MultiModalKit
import Synchronization

/// THE APP's audio session (SPEC AC-93, D-042 F-1 = B).
///
/// The library calls `activate()` before capture and `deactivate()` after
/// it — that ORDER is mechanism, and it lives in `MicrophoneSource`.
/// Everything in this file is POLICY, and policy is the app's (D-027):
/// which category, which mode, which options, and — the one that decides
/// how hard the echo problem gets — which way the sound comes out.
struct PhoneSession: AudioSessionConfiguring {
    /// Will the app SPEAK as well as listen? Recording alone is a
    /// different, easier session: no output, so no echo path at all.
    let talking: Bool
    /// Loudspeaker (the real product, loud echo) or receiver (the quiet
    /// earpiece). Ruled F-4 = A + toggle: the speaker is the default and
    /// the hard case, and BOTH get measured.
    let useSpeaker: Bool

    func activate() throws {
        let session = AVAudioSession.sharedInstance()

        // `.default` mode ON PURPOSE, carried over from the Phase 2 field
        // run: `.measurement` switches off the system's input processing
        // INCLUDING automatic gain, and the lesson was immediate — "I must
        // speak loud and be near the phone".
        if talking {
            var options: AVAudioSession.CategoryOptions = [AVAudioSession.CategoryOptions.allowBluetoothHFP]
            if useSpeaker { options.insert(.defaultToSpeaker) }
            // MODE, and it is not cosmetic. The device probe measured the
            // reply arriving at the microphone at peak 1.0000 — full
            // scale, untouched — while voice processing reported ACTIVE
            // and was visibly working on room noise (0.0092 → 0.0030).
            // So the canceller runs and simply cannot see
            // `AVSpeechSynthesizer`, which plays outside this pipeline's
            // `AVAudioEngine`. `.voiceChat` is the mode built for
            // full-duplex speech; the cheap question it answers is
            // whether the SESSION's processing covers output this app did
            // not render itself. If the probe still reads ~1.0, it does
            // not, and the honest fix is routing (SPEC §58a).
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        } else {
            try session.setCategory(.record, mode: .default)
        }
        try session.setActive(true)
    }

    func deactivate() {
        // Non-throwing by contract: this runs while something else may
        // already be going wrong, and failing to release must never mask
        // the original problem. `.notifyOthersOnDeactivation` is the
        // courtesy that lets whatever we interrupted resume.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Keeps 4c's honest witness when a REAL mind replaces the echo: the 🧠
/// line shows what the ledger delivered across the seam, whichever brain
/// answers. Reporting is the demo's concern, so the wrapper lives here
/// rather than growing the library's generator a callback it does not
/// need (AC-91's proof duty, unchanged by 4f).
struct ThoughtWitness: ReplyGenerating {
    let wrapped: any ReplyGenerating
    /// WHICH BRAIN actually answered. Not the picker's current value —
    /// the generator the coordinator really holds. A field report said
    /// "sometimes it just replies my question", and the echo mind's whole
    /// behaviour is to reply with the question, so the log has to be able
    /// to tell those two apart. An instrument that shows a number must be
    /// able to say whether it is switched on (D-054).
    let mindLabel: String
    /// The WHOLE context, not just the thought (4r). A witness that
    /// reported only the current sentence could not tell a working memory
    /// from a seam that quietly drops it — and the field report is the
    /// evidence AC-200 asks for.
    let onThought: @Sendable (ReplyContext) -> Void
    let onTurn: @Sendable (TurnReport) -> Void

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        onThought(context)
        // The CONTEXT is forwarded, not the transcript. A witness that
        // rebuilt the argument would silently drop the memory it is
        // supposed to be watching.
        let run = try await wrapped.openReply(to: context)
        return WitnessedRun(wrapped: run, heard: context.transcript,
                            mind: mindLabel, report: onTurn)
    }
}

/// One turn, as it really happened, for sharing off the phone.
///
/// Renamed from `ConversationTurn` in 4r. The library now owns that name
/// for the exchanges a mind is allowed to remember, and a demo-local type
/// with the same name would have COMPILED — silently shadowing it — which
/// is the kind of collision that is discovered a milestone late.
struct TurnReport: Sendable, Identifiable {
    let id: Int
    let mind: String
    let heard: String
    let reply: String
    let firstTokenMs: Int?
    let totalMs: Int
    let failure: String?
    /// What MLX was holding when this turn ended, in MB. THE number the
    /// model fork turns on: MLX does not mmap, so weights are resident,
    /// and a phone has a budget a Mac does not.
    let peakMemoryMB: Int?
    /// True when the stream ended with NO terminal — a barge, which is
    /// success, not a fault. Without this field a cut-off reply reads
    /// like a bug in the log.
    let bargedIn: Bool
    /// Seconds since Listen was tapped.
    ///
    /// AC-140 and AC-141 both ask for something "over time" — thermal
    /// state, time to first throttle, first-word latency across twenty
    /// minutes — and a turn carried no clock at all. Every number in the
    /// log was a point with nothing to plot it against, so a twenty-minute
    /// session would have produced a list, not a trace.
    let atSeconds: Int
    /// The thermal state WHEN THIS TURN ENDED. The status bar showed the
    /// current one and the log carried none, so a session that heated up
    /// left no evidence of when.
    let thermal: String
    /// Free dirty memory at the end of this turn, or nil when the device
    /// will not say — never 0, which is what the ambiguous API returns.
    let freeMB: Int?
    /// The MOUTH's numbers for this turn (AC-173), usually stamped after
    /// the row exists — and parked when the margin wins the race. All nil
    /// only for a BARGED reply: its mouth was cancelled, so no margin ever
    /// fires, and the empty line is the honest record. A reply whose
    /// decode FAILED does carry its line, marked DID NOT FINISH — that
    /// failure is evidence, not absence. §50 named this logging as why
    /// the session-start suspect could not be convicted from field logs.
    var voiceAudioMs: Int?
    var voiceRTF: Double?
    var cushionMs: Int?
    var voiceCompleted: Bool?
}

/// Forwards a reply untouched while writing down what crossed.
///
/// It must not change the contract it observes: whatever the inner run
/// does — tokens then one terminal, or a cancel that ends with none —
/// this passes through unchanged, and only records.
final class WitnessedRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let inner: any ReplyRun

    init(wrapped: any ReplyRun, heard: String, mind: String,
         report: @escaping @Sendable (TurnReport) -> Void) {
        self.inner = wrapped
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        let out = handle!
        Task {
            let clock = ContinuousClock()
            let start = clock.now
            var text = ""
            var first: Duration?
            var failure: String?
            var sawTerminal = false
            for await update in wrapped.updates {
                switch update {
                case .token(let token):
                    if first == nil { first = start.duration(to: clock.now) }
                    text += token
                case .failed(let why): failure = why; sawTerminal = true
                case .finished: sawTerminal = true
                }
                out.yield(update)
            }
            out.finish()
            let total = start.duration(to: clock.now)
            let ms = { (elapsed: Duration) in
                Int(Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) * 1e-15)
            }
            // The witness knows the TURN; it does not know the session.
            // `id`, the memory peak, the elapsed seconds, the thermal state
            // and the free headroom are all stamped by `record(_:)` on the
            // model, which is the only place that holds a session clock and
            // a device to ask. Placeholders here, filled there — the same
            // arrangement `id: 0` already used.
            report(TurnReport(
                id: 0, mind: mind, heard: heard, reply: text,
                firstTokenMs: first.map(ms), totalMs: ms(total),
                failure: failure, peakMemoryMB: nil, bargedIn: !sawTerminal,
                atSeconds: 0, thermal: "", freeMB: nil))
        }
    }

    func cancel() async { await inner.cancel() }
}

/// The phone's stand-in brain, identical in spirit to the Mac demo's:
/// it echoes the thought back, one token at a time, paced so the reply
/// FEELS generated and is slow enough to barge into. Tokens carry their
/// own spacing, because the phraser joins VERBATIM and never invents a
/// space (4b, D-037 F-1).
struct PhoneEchoReply: ReplyGenerating {
    /// Reports the whole thought that crossed the seam — the generator's
    /// own view, which is the only honest witness that 4c's ledger
    /// delivered everything (AC-91).
    let onThought: @Sendable (ReplyContext) -> Void

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        onThought(context)
        return PhoneEchoRun(words: ["You", " said:"]
            + context.transcript.split(separator: " ").map { " " + $0 })
    }
}

/// The felt pause, on screen (the R2 seam, D-032). Demo-tier liberty: the
/// hop to the main actor is an unstructured task (D-016).
struct PhoneLatency: LatencyReporter {
    weak var model: TranscribeModel?

    func turnLatency(_ duration: Duration, turn: Int) {
        let model = model
        Task { @MainActor in model?.show(feltPause: duration) }
    }

    func cancelLatency(_ duration: Duration, turn: Int) {
        // The barge number is the Mac demo's story; the phone's screen
        // stays quiet about it rather than growing a row nobody reads.
    }
}

private final class PhoneEchoRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(words: [String]) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        let out = handle!
        task.withLock { $0 = Task {
            for word in words {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { out.finish(); return }   // conformant:
                out.yield(.token(word))                                 // no terminal
            }
            out.yield(.finished)
            out.finish()
        } }
    }

    func cancel() async { task.withLock { $0?.cancel() } }
}
