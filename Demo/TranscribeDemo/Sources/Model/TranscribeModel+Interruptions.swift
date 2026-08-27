import AVFAudio
#if canImport(UIKit)
import UIKit
#endif
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the platform interruptions (AC-94): observing
// them, letting the live turn die honestly, and resuming on a tap.
extension TranscribeModel {
    // MARK: - interruptions (AC-94, D-042 F-2 = A and F-5 = B)

    /// The app observes the platform notification and feeds the library a
    /// plain event. The core never learns what iOS is (F-2 = A), and the
    /// library's reaction — the turn dies like a failure, the words stay —
    /// is written once, in one place, instead of once per app.
    func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in await self?.handle(interruption: type) }
        }
    }

    private func handle(interruption type: AVAudioSession.InterruptionType) async {
        switch type {
        case .began:
            // The platform already took the audio; the live turn must die
            // honestly rather than hang. Capture is torn down here too —
            // the graph is dead whether we admit it or not.
            await coordinator?.interrupt()
            wasInterrupted = true
            stop()
        case .ended:
            // NOTHING happens automatically (F-5 = B). The system's
            // `.shouldResume` hint is a hint TO THE APP; a person decides
            // when a microphone turns back on. The UI now offers it.
            break
        @unknown default:
            break
        }
    }

    // MARK: - leaving the foreground (D-079)

    /// THE CRASH THIS PREVENTS, and it is a crash, not a glitch.
    ///
    /// iOS forbids GPU work from the background. When the app leaves the
    /// foreground while the LOCAL mind is generating, Metal refuses the
    /// command buffer and MLX throws a C++ `std::runtime_error`. A C++
    /// exception crossing into Swift cannot be caught — not by the
    /// `do/catch` already wrapped around the token loop, not by anything —
    /// so `libc++abi` terminates the process. From Ryad's phone:
    ///
    ///     IOGPUMetalError: Insufficient Permission (to submit GPU work
    ///     from background)
    ///     libc++abi: terminating due to uncaught exception of type
    ///     std::runtime_error
    ///
    /// So the only cure is to not be generating when we go. Ruled out
    /// before it was tried: `beginBackgroundTask` buys CPU time and never
    /// GPU time — the restriction is on the hardware, not on the clock.
    ///
    /// **Why `willResignActive` and not `didEnterBackground`.** The later
    /// notification fires when the app is ALREADY in the background, which
    /// is already too late if a command buffer is in flight;
    /// `willResignActive` always precedes it. The cost is named rather
    /// than hidden: pulling down Control Centre or taking a call also
    /// stops the reply, so a person loses a sentence they might have
    /// kept. That trade is deliberate — a stopped reply is an annoyance a
    /// tap recovers from, and a killed process is not.
    ///
    /// **The honest limit.** Cancellation is cooperative: the token loop
    /// checks between tokens, so this wins the race only if MLX is
    /// between command buffers when the notification arrives. It makes
    /// the crash rare, and this app cannot make it impossible.
    ///
    /// The ear and the mouth need no such guard — Whisper and the neural
    /// voice run on the ANE through CoreML, which the background does not
    /// forbid. Only the MLX mind touches Metal.
    func observeForegroundLoss() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleForegroundLoss() }
        }
        #endif
    }

    /// The same two steps an audio interruption takes, and for the same
    /// reason: the live turn dies HONESTLY rather than hanging, and the
    /// words already spoken are kept.
    private func handleForegroundLoss() async {
        guard isListening else { return }
        await coordinator?.interrupt()
        wasInterrupted = true
        stop()
    }

    /// The person tapped "resume". The thought is forgotten first — a call
    /// is a break in the conversation, and a pre-call fragment must not
    /// join a post-call sentence (F-5's second half).
    func resumeAfterInterruption() async {
        await coordinator?.resume()
        wasInterrupted = false
        reply = ""
        wholeThought = ""
        start()
    }
}
