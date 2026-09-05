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
    ///
    /// **Armed at LAUNCH, not at Listen — the review's blocker (2026-08-27).**
    /// The first version registered this only inside `start()` and opened
    /// with `guard isListening`, which watches everything except the
    /// window where the danger is highest: `refreshMind()` prewarms the
    /// MLX mind during app launch, running Metal work seconds before
    /// anyone can tap anything. Backgrounding there crashed exactly as
    /// D-079 describes, through the one path the fix did not watch.
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
        // The symmetric half: coming BACK, warm the mind again so the
        // retirement above is paid for in a window the person spends
        // looking at the screen rather than waiting for a reply.
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rewarmMind()
                await self?.rewarmVoice()
            }
        }
        #endif
    }

    /// The same two steps an audio interruption takes, and for the same
    /// reason: the live turn dies HONESTLY rather than hanging, and the
    /// words already spoken are kept.
    private func handleForegroundLoss() async {
        // NO `guard isListening`. The mind can be on the GPU with no
        // conversation at all — the launch prewarm is exactly that — so a
        // guard on listening would skip the very window this exists for.
        // Retiring the mind is safe whether or not one is running:
        // `retire()` is idempotent, and the next reply rebuilds it.
        await retireLocalMind()
        // AND THE MOUTH, WHEN THE MOUTH IS ON THE GPU (4q).
        //
        // D-079 armed this guard for the MIND, because the mind was the
        // only MLX organ. Kokoro is MLX too, so this milestone handed the
        // app a second way into the identical crash: Metal work running
        // after iOS has stopped tolerating it. Qwen is CoreML and pays
        // nothing here, which is why this asks the LEVER rather than
        // retiring whatever is loaded.
        await retireVoiceIfOnGPU()
        guard isListening else { return }
        await coordinator?.interrupt()
        wasInterrupted = true
        stop()
    }

    /// Retires an MLX-backed mouth and stands a FRESH one in its place.
    ///
    /// The replacement is not optional: `retire()` is terminal by D-070 —
    /// a retired voice never loads again — so retiring without replacing
    /// would leave the app mute until relaunch. The fresh voice is
    /// unloaded and costs nothing until the next reply, and the weights
    /// are still on disk, so `modelInstalled()` stays true and the screen
    /// does not flash "install the voice" at someone who just took a
    /// phone call.
    ///
    /// The cost, named: the first reply after returning pays the model
    /// load again. That is D-079's trade, taken knowingly for the mind
    /// and taken again here for the same reason — a slow first reply
    /// beats a killed app.
    private func retireVoiceIfOnGPU() async {
        guard levers.voice == .kokoro else { return }
        let retiring = neuralVoice
        neuralVoice = levers.makeSpokenVoice()
        // AND SAY SO. The replacement is unloaded, so leaving `.ready` on
        // screen would be the state lying about the object that will
        // speak — AC-143's fault, in the one window where nobody is
        // looking and therefore nobody would catch it. `rewarmVoice()`
        // takes it back to ready.
        voiceState = .preparing
        await retiring.retire()
    }

    /// The other half of `retireVoiceIfOnGPU()`, and the half the review
    /// found missing: back in the foreground, LOAD the replacement.
    ///
    /// Without this the fresh voice stayed unloaded until the next reply
    /// asked it to speak — and `openUtterance` builds the decoder INLINE
    /// on the coordinator's one serial loop, so the first reply after a
    /// phone call paid the whole model load and kernel compile while the
    /// conversation waited. That is the exact frozen-conversation fault
    /// D-085's `ensureModel()` parity fix removed at launch, reappearing
    /// on the return path.
    ///
    /// `checkVoice()` rather than a bare `ensureModel()`: it re-reports
    /// the state as well as paying the load, and it already refuses when
    /// the mind has claimed the memory (§27) or the weights are missing.
    func rewarmVoice() async {
        guard mouth == .neural, levers.voice == .kokoro else { return }
        await checkVoice()
    }

    /// The person tapped "resume". The thought is forgotten first — a call
    /// is a break in the conversation, and a pre-call fragment must not
    /// join a post-call sentence (F-5's second half).
    func resumeAfterInterruption() async {
        await coordinator?.resume()
        wasInterrupted = false
        reply = ""
        wholeThought = ""
        remembering = ""
        start()
    }
}
