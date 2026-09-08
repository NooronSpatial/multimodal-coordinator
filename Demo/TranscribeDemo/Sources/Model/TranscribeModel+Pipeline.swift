import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the pipeline: what refuses to start, starting and
// stopping it, and the platform interruptions that end it.
extension TranscribeModel {
    /// WHY TAPPING LISTEN WOULD DO NOTHING, or nil — and the ONE place that
    /// decides it.
    ///
    /// There used to be two lists, and they drifted. The button disabled on
    /// three conditions; `start()` refused on five. The two it did not know
    /// about were a shield probe holding the audio session, and a neural
    /// voice that is not ready — both reachable, both producing exactly the
    /// silent dead button AC-110 forbids. Worse after the tab split: the
    /// evidence for both now lives in OTHER tabs, so the person tapping
    /// Listen could not even see the reason.
    ///
    /// So `start()` asks this, and the button asks this, and there is
    /// nothing left to drift. It returns a SENTENCE because a disabled
    /// control that cannot say why is only half honest.
    var listenRefusal: String? {
        // ARABIC HAS ONE CITIZEN PER ORGAN (4u, INSTRUMENTS §62): the app
        // says which, in a sentence a person can act on, rather than
        // switching organs behind their back.
        if language == .arabic {
            if choice == .apple { return "Apple's ear has no Arabic — switch the ear to Whisper" }
            if talkEnabled, mind == .apple { return "Apple's mind has no Arabic — switch the mind to Local" }
            if talkEnabled, mouth == .neural { return "no neural voice speaks Arabic — switch the voice to Apple" }
        }
        if engineState != .ready { return "the speech model is not ready yet" }
        if probeStatus != nil {
            return "an echo probe is measuring — it holds the audio session"
        }
        if shieldStatus != nil {
            return "the shield probe is measuring — it holds the audio session"
        }
        if let conflict = memoryConflict { return conflict }
        if talkEnabled, mouth == .neural, voiceState != .ready {
            // THE STATE, NOT ONE SENTENCE FOR ALL OF THEM. This said
            // "install it in Settings" for every non-ready state — including
            // the seconds after a lever change, when the voice is LOADING
            // and installing is precisely the wrong advice. Ryad asked what
            // to do while it swaps, which is how the message was found.
            switch voiceState {
            case .modelMissing:
                return "the neural voice is not installed — install it in Settings"
            case .downloading:
                return "the neural voice is downloading"
            case .checking, .preparing:
                return "the neural voice is loading — it will start on its own"
            case .failed(let why):
                return "the neural voice failed: \(why)"
            case .ready:
                return nil      // unreachable; the guard above excluded it
            }
        }
        // ANY mind that cannot answer, not just Apple's: the review found
        // the Local mind able to start a session in which every turn fails
        // at the door — a dead conversation that looks alive.
        if talkEnabled, mind != .echo, let why = mindAssets.unavailable { return why }
        return nil
    }

    private var engine: any TranscriptionEngine {
        choice == .apple ? appleEngine : whisperEngine
    }

    // MARK: - the pipeline

    func start() {
        // The gate is SYMMETRIC (4d review). MicrophoneSource enforces
        // "activate once, release after the engine stops" per INSTANCE,
        // but PhoneSession acts on the process-wide AVAudioSession. The
        // probe already refused to run while listening; nothing stopped
        // listening from starting while a probe held the session, which
        // reconfigured it under a live tap and then released it under a
        // running graph — verbatim both failures the seam exists to
        // prevent.
        // The VOICE must be ready too, or the first reply fails
        // mid-turn with a missing model — a failure the screen would
        // report as a turn error when it is really a setup problem.
        // The MIND must be ready too, symmetrically with the voice: a
        // turn that dies on .modelNotReady is a setup problem the screen
        // would misreport as a turn error. Availability is read fresh —
        // the download may have finished since the last look.
        refreshMind()
        sessionStart = ContinuousClock().now
        guard listenRefusal == nil, !isListening
        else { return }
        clearLastSession()

        // ~1.4 s of audio at 48 kHz; power-of-two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 16)
        // The session is handed to the LIBRARY, which orders its steps
        // around capture (D-042 F-1 = B). The app never calls setActive
        // by hand any more — that ordering was guaranteed by nobody.
        let microphone = makeMicrophone()
        do {
            try microphone.start(into: producer)
        } catch {
            engineState = .failed("Microphone: \(error.localizedDescription)")
            return
        }
        self.microphone = microphone
        observeInterruptions()
        // The GPU guard (D-079). Registered beside the audio one because
        // they answer the same question — "the platform is taking
        // something away, what must stop first?" — and because both must
        // be live for exactly as long as a conversation is.
        observeForegroundLoss()

        // THE POINT OF AC-104 (D-048, AC-108). The reply renders on the
        // CAPTURE engine — the one whose audio unit does the echo
        // cancelling — because D-043 measured that iOS voice processing
        // removes only what that unit itself renders. Every earlier
        // reply, Apple's included, was rendered somewhere the canceller
        // could not see, which is why the probe read 0.94-1.00 with the
        // canceller demonstrably working on everything else.
        //
        // AFTER `start`, never before: the host refuses to attach to a
        // microphone that is not capturing, and it is right to.

        let rate = microphone.sampleRate
        let captureHost = microphone.playbackHost
        // THE FRONT DOOR (4t, D-093). The pump, the session, the
        // coordinator, the listener order, the task group and the
        // teardown order are the runtime's now. What stays in this file is
        // every POLICY number this phone earned, passed in and visible.
        let runtime = AIRuntime(makeConfiguration(reading: consumer, at: rate,
                                                  hostedOn: microphone))
        isListening = true
        inputPeak = 0
        pipeline = Task { [weak self] in
            guard let self else { return }
            // The voice is hosted BEFORE any loop runs — the same
            // guarantee the hand-wired version had by construction, kept
            // explicit here rather than left to a race the first reply
            // would usually, but not always, win.
            await self.hostVoice(captureHost: captureHost)
            await runtime.run { session in await self.observe(session) }
        }
    }

    /// The screen's own state, cleared before a new session writes to it.
    private func clearLastSession() {
        utterances.removeAll()
        droppedFrames = 0
        reply = ""
        wholeThought = ""
        remembering = ""
        feltPauseMilliseconds = nil
        wasInterrupted = false
    }

    /// The capture side, configured from what the person chose.
    private func makeMicrophone() -> MicrophoneSource {
        MicrophoneSource(
            // Voice processing only when there is something to cancel.
            // Its numbers were measured on a Mac whose microphone is an
            // iPhone over Continuity — none of them transfer, so AC-96
            // re-measures here or claims nothing.
            voiceProcessing: talkEnabled,
            session: PhoneSession(talking: talkEnabled, useSpeaker: useSpeaker),
            // THE SHIELD (4g, AC-120). D-049 turned this off when the
            // hosted arrangement killed capture; the shield matrix then
            // measured WHY (a Mac fact plus an ordering bug plus session
            // contamination) and found the calm arrangement — chain
            // before vp, restart as the belt (INSTRUMENTS §23). Opt-in
            // by ruling (D-060 F-4): the person flips it, the library
            // never assumes it.
            hostsPlayback: talkEnabled && speakerShield)
    }

    /// Every policy value this phone earned, passed through UNTOUCHED
    /// (AC-204). The runtime adds none of its own; each number below keeps
    /// the ruling that put it here.
    private func makeConfiguration(
        reading consumer: AudioRingConsumer, at rate: Double,
        hostedOn microphone: MicrophoneSource
    ) -> AIRuntime<ContinuousClock>.Configuration {
        let chunk = Int(rate * 0.02)                       // 20 ms per verdict
        let host = neuralHost
        return .init(
            consumer: consumer,
            // 0.01 was earned in Phase 2, when this app only LISTENED —
            // no speaker, so no echo to cross it. The first 4d field run
            // showed the assistant barging itself on the phone, which is
            // that number meeting a loudspeaker centimetres from the
            // microphone. It is adjustable on screen now, because AC-97
            // says this device earns its own numbers from a run rather
            // than inheriting the Mac's.
            vad: EnergyVAD(config: .init(threshold: vadThreshold,
                                         hangoverFrames: Int(rate * 0.3))),
            // The ear the person picked.
            ear: engine,
            // The conversation, if the app is talking (F-3 = B: mind and
            // mouth together, or neither). Same coordinator, same ledger,
            // same phraser, same mouth as the Mac — AC-92's whole point is
            // that none of them needed an iOS variant.
            mind: talkEnabled ? currentGenerator : nil,
            mouth: talkEnabled
                ? currentMouth(shieldHost: speakerShield ? microphone.playbackHost : nil)
                : nil,
            // 200 ms of pre-roll: a word's quiet onset must survive a VAD
            // that only wakes on its loud middle.
            pump: .init(sampleRate: rate, pollInterval: .milliseconds(10),
                        chunkFrames: chunk, preRollChunks: 10),
            transcription: .init(format: AudioStreamFormat(sampleRate: rate, channels: 1)),
            // THE REPLY GATE, at last switched on (F-2 = B, 500 ms).
            //
            // AC-81 built this in 4c and the demo never set it, so the
            // assistant committed about 300 ms after Ryad stopped making
            // noise — less than a person's thinking pause. A 38-turn
            // field session measured the cost: SIX turns opened on a
            // fragment ("Okay, and uh,") and were killed 76 ms later by
            // him finishing his own sentence, and twelve carried a
            // previous turn's words forward.
            //
            // POLICY, in the app, on purpose (D-027): the library's
            // default stays `.zero`. This number costs felt pause 1:1 —
            // 542 ms measured becomes about 1040 ms — and that is a
            // trade only the person holding the phone can price.
            turns: .init(
                replyGate: .milliseconds(500),
                // THE APP CHOOSES (D-027). This phone hears itself: with
                // the shield on, its own cancelled reply still crosses
                // the gate, and §43 measured the leak dying under 530 ms
                // while real speech runs past 930. Ryad ruled 600 ms.
                bargeWindow: BargeWindow.measured,
                // 4r, AC-197: the lever, read once when the session
                // starts. The character budget keeps the library's
                // default (D-092) — this phone's mind has no 4096-token
                // ceiling, and the depth is the axis that was measured.
                maxMemoryTurns: memoryDepth),
            clock: ContinuousClock(),
            diagnostics: diagnostics,
            // THIS APP's ruling (D-027/D-028): on a hot phone, sacrifice
            // the late settling decodes, loudly — the row will say so.
            thermalPolicy: ConservativeThermalPolicy(),
            latencyReporter: PhoneLatency(model: self),
            // THE TEARDOWN'S BODIES; the runtime owns the ORDER (AC-203).
            // Step 2: the render engine's nodes go, safely, after the
            // pipeline has drained — step 2 was missing entirely for a
            // milestone, and the person's music never came back.
            stopRendering: { host.stopRendering() },
            // Step 3: the session goes LAST; it cannot be released
            // before the engine stops (`IsBusy`, swallowed by a `try?`).
            releaseSource: { [weak self] in
                await MainActor.run { self?.microphone?.stop() }
            })
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        isSpeaking = false
        turnState = .idle
        // THE ORDER HERE IS THE FIX (4e review, blocker 2), and it has
        // three steps that cannot be swapped:
        //
        //   1. the pipeline dies      — so no reply is still speaking
        //   2. the render engine stops — its nodes go, safely, after 1
        //   3. the session is released — it cannot be, before 2
        //
        // Step 2 was missing entirely: nothing ever stopped the engine
        // the neural voice renders on, so `setActive(false)` failed with
        // `IsBusy`, `PhoneSession` swallowed it with `try?`, and the
        // .playAndRecord session stayed held for the life of the app —
        // the person's music never came back.
        //
        // Step 2 WAITS for step 1 rather than racing it: `stopRendering`
        // detaches nodes, and a reply still calling `play()` on a
        // detached node aborts the process. That is the same abort as
        // blocker 1, reached from the other side.
        //
        // Steps 2 and 3 are the RUNTIME's now (4t, AC-203): it stops the
        // rendering and releases the source in that order, on its own way
        // out. What is left here is to cancel, wait for it to have done
        // so, and drop the handle.
        let dying = pipeline
        pipeline = nil
        dying?.cancel()
        Task {
            await dying?.value               // the teardown has run, in order
            await MainActor.run { microphone = nil }
        }
        coordinator = nil
        // BOTH observers go. The foreground one was added in the same
        // breath as the audio one and must leave in the same breath: an
        // observer outliving its pipeline would interrupt a coordinator
        // that no longer exists on the next Control Centre swipe.
        // The foreground observers are NOT removed here any more. They
        // are armed at launch and must outlive any single conversation:
        // the MLX mind runs on the GPU during the launch prewarm, with no
        // pipeline at all, which is the window the review found unguarded.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    /// A toggle flipped mid-run rebuilds the pipeline. `stop()` only
    /// CANCELS the old task, so without awaiting it the previous run's
    /// buffered events could still drain into the fresh one and corrupt
    /// the forensics (4d review). Awaiting the cancelled task first makes
    /// the handover clean.
    func restart() {
        let dying = pipeline
        stop()
        Task { [weak self] in
            _ = await dying?.value
            self?.start()
        }
    }

    /// Where the reply renders, decided BEFORE the first loop runs.
    private func hostVoice(captureHost: MicrophonePlaybackHost) async {
        guard mouth == .neural else { return }
        // WHERE THE REPLY RENDERS (4g): behind the shield it goes to the
        // CAPTURE engine's host — the whole point, the canceller can only
        // remove what its own unit renders (D-043). Unshielded, the 4e
        // arrangement stands.
        await neuralVoice.render(on: speakerShield ? captureHost : neuralHost)
        await neuralVoice.reportMargins { margin in
            // The graph's rate is refreshed HERE, with the margin, because
            // it only becomes real when a reply has actually rendered: the
            // host records it during attach rather than by poking a mixer
            // that may not exist yet. Asking at start-up would have
            // printed "not rendered yet" forever, which is the same family
            // of mistake as the instrument that shipped dead an hour ago.
            Task { @MainActor in
                self.voiceMargin = margin
                self.attach(margin)
            }
        }
    }

    /// The screen, observing the session (4t). One nested group of UI
    /// consumers, children of the runtime's group so a cancel reaches
    /// every one (D-014). The listeners arrive ALREADY OPEN — the runtime
    /// opened them before it started a single loop, which is the rule this
    /// file used to state in a comment and enforce with nothing.
    private func observe(_ session: AIRuntime<ContinuousClock>.Session) async {
        // The handle the app steers — interrupt, resume, clear memory —
        // and never stops: stopping is the runtime's, in order.
        coordinator = session.conversation
        await withTaskGroup(of: Void.self) { group in
            if let turns = session.turns {
                group.addTask { [weak self] in
                    for await event in turns.events {
                        await self?.show(turn: event)
                    }
                }
            }
            if let health = session.health {
                group.addTask { [weak self] in
                    for await event in health.events {
                        await self?.show(health: event)
                    }
                }
            }
            group.addTask { [weak self] in
                for await event in session.audio.events {
                    await self?.show(audio: event)
                }
            }
            group.addTask { [weak self] in
                for await event in session.transcripts.events {
                    await self?.show(transcript: event)
                }
            }
            // THE LEVEL METER. A poll, deliberately: the level is a
            // lock-free atomic written by the audio thread, and the
            // screen only needs it as fast as a person can read it.
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let (level, alive, reconfigs) = await MainActor.run {
                        (self.microphone?.inputLevel ?? 0,
                         self.microphone?.engineIsRunning ?? false,
                         self.microphone?.configurationChanges ?? 0)
                    }
                    await MainActor.run {
                        self.inputLevel = level
                        self.inputPeak = max(self.inputPeak, level)
                        self.engineAlive = alive
                        self.engineReconfigurations = reconfigs
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            // The wall, one level down: the first stream to END means the
            // runtime is stopping its actors, so the poller — which ends
            // only on cancellation — is cancelled here rather than left to
            // hold this scope open.
            _ = await group.next()
            group.cancelAll()
        }
    }
}
