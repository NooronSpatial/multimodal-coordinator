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
        let chunk = Int(rate * 0.02)                       // 20 ms per verdict
        let pump = makePump(reading: consumer, at: rate, chunkFrames: chunk)
        let transcription = makeTranscription(at: rate)

        let coordinator = makeCoordinator(hostedOn: microphone)
        self.coordinator = coordinator

        isListening = true
        inputPeak = 0
        let diagnostics = diagnostics
        // NO HOST IS INSTALLED (D-049). The voice makes its own engine,
        // which is the configuration that has worked since the hour it
        // was written. What stays is the margin reporting: the decode
        // numbers are how anyone will know whether this phone can run
        // this voice at all, and they do not depend on where it renders.
        let captureHost = microphone.playbackHost
        pipeline = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(pump: pump, transcription: transcription,
                                   coordinator: coordinator, diagnostics: diagnostics,
                                   captureHost: captureHost)
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

    /// The pump that turns the ring into verdicts, at the gate this
    /// device is currently set to.
    private func makePump(reading consumer: AudioRingConsumer,
                          at rate: Double,
                          chunkFrames chunk: Int) -> AudioPump<ContinuousClock> {
        AudioPump(
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
            clock: ContinuousClock(),
            // 200 ms of pre-roll: a word's quiet onset must survive a VAD
            // that only wakes on its loud middle.
            config: .init(sampleRate: rate, pollInterval: .milliseconds(10),
                          chunkFrames: chunk, preRollChunks: 10),
            diagnostics: diagnostics)
    }

    /// The decoding side, on the ear the person picked.
    private func makeTranscription(at rate: Double) -> TranscriptionSession {
        TranscriptionSession(
            engine: engine,
            config: .init(format: AudioStreamFormat(sampleRate: rate, channels: 1)),
            diagnostics: diagnostics,
            // THIS APP's ruling (D-027/D-028): on a hot phone, sacrifice the
            // late settling decodes, loudly — the row will say so in words.
            thermalPolicy: ConservativeThermalPolicy())
    }

    /// The conversation, if the app is talking. Same coordinator, same
    /// ledger, same phraser, same mouth as the Mac — AC-92's whole
    /// point is that none of them needed an iOS variant.
    private func makeCoordinator(
        hostedOn microphone: MicrophoneSource
    ) -> TurnCoordinator<ContinuousClock>? {
        talkEnabled
            ? TurnCoordinator(
                replyGenerator: currentGenerator,
                synthesizer: currentMouth(shieldHost: speakerShield ? microphone.playbackHost : nil),
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
                // The gate holds the reply, and `handleGateExpired` builds
                // the prompt when it EXPIRES — so a continued sentence joins
                // the SAME thought, and a new utterance during the gate stops
                // the turn firing at all.
                //
                // POLICY, in the app, on purpose (D-027): the library's
                // default stays `.zero`. This number costs felt pause 1:1 —
                // 542 ms measured becomes about 1040 ms — and that is a
                // trade only the person holding the phone can price.
                config: .init(
                    replyGate: .milliseconds(500),
                    // THE APP CHOOSES (D-027). This phone hears itself: with
                    // the shield on, its own cancelled reply still crosses
                    // the gate, and §43 measured the leak dying under 530 ms
                    // while real speech runs past 930. Ryad ruled 600 ms.
                    bargeWindow: BargeWindow.measured,
                    // 4r, AC-197: the lever, read once when the session
                    // starts. The character budget keeps the library's
                    // default — this phone's mind has no 4096-token
                    // ceiling, and the depth is the axis being measured.
                    maxMemoryTurns: memoryDepth),
                clock: ContinuousClock(),
                latencyReporter: PhoneLatency(model: self),
                // D-059 = A: dead turns reach the health stream — the road
                // the mind's tripwire alarm rides.
                diagnostics: diagnostics)
            : nil
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
        let dying = pipeline
        pipeline = nil
        dying?.cancel()
        let host = neuralHost
        Task {
            await dying?.value               // the pipeline has drained
            host.stopRendering()             // now the nodes are nobody's
            await MainActor.run { microphone?.stop() }   // and the session goes
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

    /// The conversation's own task tree, lifted out of `start()`.
    ///
    /// It is ONE structured group on purpose (D-014): every listener is a
    /// child of this task, so cancelling `pipeline` cancels all of them and
    /// none can outlive the conversation that made it.
    private func runPipeline(pump: AudioPump<ContinuousClock>,
                             transcription: TranscriptionSession,
                             coordinator: TurnCoordinator<ContinuousClock>?,
                             diagnostics: PipelineDiagnostics,
                             captureHost: MicrophonePlaybackHost) async {
        if mouth == .neural {
            // WHERE THE REPLY RENDERS (4g): behind the shield it
            // goes to the CAPTURE engine's host — the whole point,
            // the canceller can only remove what its own unit
            // renders (D-043). Unshielded, the 4e arrangement stands.
            await neuralVoice.render(on: speakerShield ? captureHost : neuralHost)
            await neuralVoice.reportMargins { margin in
                // The graph's rate is refreshed HERE, with the
                // margin, because it only becomes real when a reply
                // has actually rendered: the host records it during
                // attach rather than by poking a mixer that may not
                // exist yet. Asking at start-up would have printed
                // "not rendered yet" forever, which is the same
                // family of mistake as the instrument that shipped
                // dead an hour ago.
                Task { @MainActor in
                    self.voiceMargin = margin
                    self.attach(margin)
                }
            }
        }
        // Listeners are taken BEFORE the pumps run: no event is missed.
        let audioForSession = await pump.listen()
        let audioForUI = await pump.listen()          // the multicast, used for real
        let transcripts = await transcription.listen()
        let health = diagnostics.health()
        let audioForTurns = coordinator == nil ? nil : await pump.listen()
        let transcriptsForTurns = coordinator == nil ? nil : await transcription.listen()
        let turnEvents = coordinator == nil ? nil : await coordinator?.listen()

        await runListeners(pump: pump, transcription: transcription,
                           coordinator: coordinator, diagnostics: diagnostics,
                           health: health,
                           audioForSession: audioForSession, audioForUI: audioForUI,
                           transcripts: transcripts, audioForTurns: audioForTurns,
                           transcriptsForTurns: transcriptsForTurns, turnEvents: turnEvents)
    }

    // swiftlint:disable function_parameter_count function_body_length
    /// The task GROUP itself: one child per listener, all of them children
    /// of the caller's task so a cancel reaches every one (D-014).
    ///
    /// The long parameter list is the point rather than a smell: these are
    /// the ALREADY-OPENED listener handles. Opening them inside this
    /// function would change WHO subscribes first, and subscription order
    /// is the one thing the multicast's drop accounting depends on. The
    /// body is one `addTask` per listener — long, but flat and additive,
    /// and splitting it would scatter a task tree that must be read whole.
    private func runListeners(pump: AudioPump<ContinuousClock>,
                              transcription: TranscriptionSession,
                              coordinator: TurnCoordinator<ContinuousClock>?,
                              diagnostics: PipelineDiagnostics,
                              health: Broadcast<HealthEvent>.Listener,
                              audioForSession: Broadcast<AudioEvent>.Listener,
                              audioForUI: Broadcast<AudioEvent>.Listener,
                              transcripts: Broadcast<TranscriptEvent>.Listener,
                              audioForTurns: Broadcast<AudioEvent>.Listener?,
                              transcriptsForTurns: Broadcast<TranscriptEvent>.Listener?,
                              turnEvents: Broadcast<TurnEvent>.Listener?) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.run() }
            group.addTask { await transcription.run(events: audioForSession.events) }
            if let coordinator, let audioForTurns, let transcriptsForTurns {
                group.addTask {
                    await coordinator.run(audio: audioForTurns.events,
                                          transcripts: transcriptsForTurns.events)
                }
            }
            if let turnEvents {
                group.addTask { [weak self] in
                    for await event in turnEvents.events {
                        await self?.show(turn: event)
                    }
                }
            }
            // The thermal watcher — cancelled with the group, never
            // stop()ped: diagnostics lives across Listen sessions.
            group.addTask { await diagnostics.run() }
            group.addTask { [weak self] in
                for await event in health.events {
                    await self?.show(health: event)
                }
            }
            group.addTask { [weak self] in
                for await event in audioForUI.events {
                    await self?.show(audio: event)
                }
            }
            // THE LEVEL METER. A poll, deliberately: the level is a
            // lock-free atomic written by the audio thread, and the
            // screen only needs it as fast as a person can read it.
            // Nothing downstream depends on this task, and it ends
            // with the group like everything else here.
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
            group.addTask { [weak self] in
                for await event in transcripts.events {
                    await self?.show(transcript: event)
                }
            }
            // The group is the wall: stop() ends the streams, then this
            // scope drains and returns. Nothing outlives the pipeline.
            _ = await group.next()
            await pump.stop()
            await transcription.stop()
            await coordinator?.stop()
        }
    }
    // swiftlint:enable function_parameter_count function_body_length
}
