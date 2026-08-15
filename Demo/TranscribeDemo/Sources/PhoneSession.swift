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
            var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
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

/// The phone's stand-in brain, identical in spirit to the Mac demo's:
/// it echoes the thought back, one token at a time, paced so the reply
/// FEELS generated and is slow enough to barge into. Tokens carry their
/// own spacing, because the phraser joins VERBATIM and never invents a
/// space (4b, D-037 F-1).
struct PhoneEchoReply: ReplyGenerating {
    /// Reports the whole thought that crossed the seam — the generator's
    /// own view, which is the only honest witness that 4c's ledger
    /// delivered everything (AC-91).
    let onThought: @Sendable (String) -> Void

    func openReply(to transcript: String) async throws -> any ReplyRun {
        onThought(transcript)
        return PhoneEchoRun(words: ["You", " said:"]
            + transcript.split(separator: " ").map { " " + $0 })
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
