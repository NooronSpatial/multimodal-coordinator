import AVFAudio
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
