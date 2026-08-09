/// The bridge from utterances to text (SPEC AC-23…AC-32).
///
/// Consumes the pump's `AudioEvent`s, opens ONE recognition per utterance,
/// feeds it every chunk the pump published for that utterance — pre-roll
/// included — and publishes `TranscriptEvent`s to any number of listeners.
///
/// The law it exists to enforce (D-019): recognition is slow and speech does
/// not wait. An engine may answer after its utterance is long over — so every
/// utterance carries a ticket, checked in the same actor step that could
/// retire it. A dead utterance's words can never reach a listener.
/// Cancellation is the optimisation; the ticket is the guarantee.
///
/// The shape (one loop, one truth): everything the session reacts to — audio
/// events, engine updates, the stop request — is merged into ONE stream and
/// handled by ONE loop on the actor. Engine readers are group children that
/// only forward into the merge; they never touch the actor. So there is no
/// racing pair of readers, no stored task, and every state change happens in
/// loop order.
///
/// Deliberately clockless: the ceiling (AC-26) is counted in FRAMES of audio,
/// and every event is stamped in audio time (D-011, D-021).
public actor TranscriptionSession {
    public struct Config: Sendable {
        /// The shape of the audio the pump delivers.
        public var format: AudioStreamFormat
        /// The ceiling: audio longer than this is cut with `truncated` (AC-26).
        public var maximumUtterance: Duration
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int

        public init(
            format: AudioStreamFormat = AudioStreamFormat(),
            maximumUtterance: Duration = .seconds(30),
            listenerBufferCapacity: Int = Broadcast<TranscriptEvent>.defaultBufferCapacity
        ) {
            self.format = format
            self.maximumUtterance = maximumUtterance
            self.listenerBufferCapacity = listenerBufferCapacity
        }
    }

    /// Everything that can wake the loop, in one type.
    private enum Input: Sendable {
        case audio(AudioEvent)
        case update(utterance: Int, TranscriptionUpdate)
        case audioEnded
        case stopped
    }

    /// The one open-or-settling recognition. `active == nil` means every
    /// earlier utterance is dead — that nil IS the retired ticket.
    private struct Active {
        let utterance: Int
        let run: any TranscriptionRun
        let startFrames: Int
        var fedFrames = 0
        var settling = false
        var truncated = false
    }

    private let engine: any TranscriptionEngine
    private let config: Config
    private let broadcast: Broadcast<TranscriptEvent>
    /// The ceiling in frames — the Duration is converted once, here, and time
    /// never appears again.
    private let ceilingFrames: Int

    private var active: Active?
    private var nextUtterance = 0
    private var merge: AsyncStream<Input>.Continuation?
    private var isStopped = false

    public init(engine: any TranscriptionEngine, config: Config = Config()) {
        self.engine = engine
        self.config = config
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
        let seconds = Double(config.maximumUtterance.components.seconds)
            + Double(config.maximumUtterance.components.attoseconds) * 1e-18
        self.ceilingFrames = Int((seconds * config.format.sampleRate).rounded())
    }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<TranscriptEvent>.Listener {
        broadcast.listen()
    }

    /// Consumes audio events until the stream ends or `stop()` is called.
    /// Structured: the forwarders live and die inside this call's task group.
    public func run(events: AsyncStream<AudioEvent>) async {
        guard !isStopped, merge == nil else { return }

        var handle: AsyncStream<Input>.Continuation!
        let inputs = AsyncStream<Input>(bufferingPolicy: .unbounded) { handle = $0 }
        let input = handle!
        merge = input

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events { input.yield(.audio(event)) }
                input.yield(.audioEnded)
            }

            var audioOver = false
            loop: for await item in inputs {
                if isStopped { break }
                switch item {
                case .audio(let event):
                    await handleAudio(event, forwardingInto: &group, via: input)
                case .update(let utterance, let update):
                    handleUpdate(update, utterance: utterance)
                case .audioEnded:
                    audioOver = true
                    // Input died mid-utterance: settle the run so its words
                    // are not lost; the loop then waits for its final.
                    if let current = active, !current.settling {
                        active?.settling = true
                        await current.run.finishAudio()
                    }
                case .stopped:
                    break loop
                }
                // Graceful end: audio is over and nothing is settling.
                if audioOver && active == nil { break }
            }
            group.cancelAll()   // frees any forwarder stuck on a defiant stream
        }

        merge = nil
        broadcast.finish()
    }

    /// Ends the session: the open recognition is cancelled, its ticket dies
    /// in this same actor step, and every listener's stream finishes (AC-32).
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let dying = active
        active = nil                       // the ticket dies HERE — no gap
        merge?.yield(.stopped)
        broadcast.finish()
        if let dying { await dying.run.cancel() }   // optimisation, after the guarantee
    }

    // MARK: - audio events (one at a time, in loop order)

    private func handleAudio(
        _ event: AudioEvent,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        switch event {
        case .speechStarted(let at):
            // D-021 ruling 1: a new utterance retires the settling one.
            if let old = active {
                active = nil               // ticket dead before any await
                await old.run.cancel()
            }
            let utterance = nextUtterance
            nextUtterance += 1
            do {
                let run = try await engine.openRun(format: config.format)
                // Reentrancy law: stop() may have run while we awaited.
                guard !isStopped else { await run.cancel(); return }
                active = Active(utterance: utterance, run: run, startFrames: at.frames)
                group.addTask {
                    for await update in run.updates {
                        input.yield(.update(utterance: utterance, update))
                    }
                }
            } catch let failure as TranscriptionFailure {
                publish(.failed(failure, utterance: utterance, at: at))   // D-021 ruling 4
            } catch {
                publish(.failed(.engineFailed(String(describing: error)),
                                utterance: utterance, at: at))
            }

        case .audioSegment(let chunk):
            guard var current = active, !current.truncated, !current.settling else { return }

            if current.fedFrames + chunk.frameCount > ceilingFrames {
                // The ceiling (AC-26, D-021 ruling 3): announce the cut, stop
                // feeding, settle the run — its final may still arrive.
                current.truncated = true
                current.settling = true
                active = current           // flags set BEFORE the await
                publish(.truncated(utterance: current.utterance,
                                   at: time(current.startFrames + current.fedFrames)))
                await current.run.finishAudio()
                return
            }

            let utterance = current.utterance
            await current.run.feed(chunk)
            // Reentrancy law: the world may have changed during the feed.
            guard active?.utterance == utterance else { return }
            current.fedFrames += chunk.frameCount
            active = current

        case .speechEnded:
            guard let current = active, !current.settling else { return }
            active?.settling = true
            await current.run.finishAudio()

        case .dropped:
            break   // the pump's honesty about lost sound; not text business
        }
    }

    // MARK: - engine updates (the ticket's door)

    private func handleUpdate(_ update: TranscriptionUpdate, utterance: Int) {
        // THE TICKET (AC-25, D-019): checked in the same actor step that can
        // retire it. A dead utterance's words stop at this line.
        guard let current = active, current.utterance == utterance else { return }

        // D-021 ruling 2: stamped with the audio already fed to this run.
        let at = time(current.startFrames + current.fedFrames)

        switch update {
        case .partial(let text):
            publish(.partial(text, utterance: utterance, at: at))
        case .final(let text):
            publish(.final(text, utterance: utterance, at: at))
            active = nil                   // after the final: nothing, ever (AC-28)
        case .failed(let failure):
            publish(.failed(failure, utterance: utterance, at: at))
            active = nil                   // failure ends the utterance, not the session (AC-29)
        }
    }

    private func publish(_ event: TranscriptEvent) {
        broadcast.publish(event)
    }

    private func time(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: config.format.sampleRate)
    }
}
