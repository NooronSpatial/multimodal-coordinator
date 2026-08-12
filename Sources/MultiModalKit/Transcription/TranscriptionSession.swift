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

    /// The one recognition being FED. For streaming engines, `active == nil`
    /// means every earlier utterance is dead — that nil IS the retired
    /// ticket. For batch engines (D-024), a run leaves `active` on the next
    /// `speechStarted` but keeps its ticket in `settlingRuns` until its
    /// final, its failure, or `stop()`.
    private struct Active {
        let utterance: Int
        let run: any TranscriptionRun
        let startFrames: Int
        var fedFrames = 0
        var settling = false
        var truncated = false
        /// Instruments spans (AC-45): the whole utterance, and — once
        /// settling — the pause a user would feel. Actor-internal only.
        var utteranceSpan: PipelineSignposter.Span?
        var settleSpan: PipelineSignposter.Span?
    }

    /// A batch run whose audio is over and whose decode is still working.
    /// Its `at` is fixed at settle time — the audio it was fed is complete.
    private struct Settling {
        let run: any TranscriptionRun
        let at: AudioTime
        var utteranceSpan: PipelineSignposter.Span?
        var settleSpan: PipelineSignposter.Span?
    }

    private let engine: any TranscriptionEngine
    private let config: Config
    private let broadcast: Broadcast<TranscriptEvent>
    /// The ceiling in frames — the Duration is converted once, here, and time
    /// never appears again.
    private let ceilingFrames: Int

    private var active: Active?
    /// D-024: settling batch runs, by utterance number — each keeps its
    /// ticket until its final arrives. Streaming engines never enter here.
    private var settlingRuns: [Int: Settling] = [:]
    private let allowsOverlap: Bool
    private var nextUtterance = 0
    private var merge: AsyncStream<Input>.Continuation?
    private var isStopped = false

    private let diagnostics: PipelineDiagnostics?
    /// D-028: consulted at the settling-move only; nil = never decline.
    private let thermalPolicy: (any ThermalPolicy)?

    public init(
        engine: any TranscriptionEngine,
        config: Config = Config(),
        diagnostics: PipelineDiagnostics? = nil,
        thermalPolicy: (any ThermalPolicy)? = nil
    ) {
        self.engine = engine
        self.config = config
        self.diagnostics = diagnostics
        self.thermalPolicy = thermalPolicy
        let onDrop: (@Sendable (Int, Int) -> Void)?
        if let diagnostics {
            onDrop = { id, total in
                diagnostics.noteListenerLoss(listenerID: id, totalDropped: total)
            }
        } else {
            onDrop = nil
        }
        self.broadcast = Broadcast(
            bufferCapacity: config.listenerBufferCapacity, onListenerDrop: onDrop)
        self.allowsOverlap = engine.capabilities.wantsWholeUtterance
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
                        active?.settleSpan = diagnostics?.signposts.begin("session.settle")
                        await current.run.finishAudio()
                    }
                case .stopped:
                    break loop
                }
                // Graceful end: audio is over and no decode is still working.
                if audioOver && active == nil && settlingRuns.isEmpty { break }
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
        let dyingActive = active
        let dyingSettling = settlingRuns
        active = nil                       // every ticket dies HERE — no gap
        settlingRuns.removeAll()
        diagnostics?.noteSettlingDecodes(count: 0)
        if let dyingActive {
            endSpans(utteranceSpan: dyingActive.utteranceSpan, settleSpan: dyingActive.settleSpan)
        }
        for (_, settled) in dyingSettling {
            endSpans(utteranceSpan: settled.utteranceSpan, settleSpan: settled.settleSpan)
        }
        merge?.yield(.stopped)
        broadcast.finish()
        if let dyingActive { await dyingActive.run.cancel() }   // optimisation,
        for (_, settling) in dyingSettling {                    // after the
            await settling.run.cancel()                         // guarantee
        }
    }

    // MARK: - audio events (one at a time, in loop order)

    private func handleAudio(
        _ event: AudioEvent,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        switch event {
        case .speechStarted(let at):
            if let old = active {
                active = nil               // decided in this same actor step
                if allowsOverlap && old.settling {
                    // D-028: the ONE consultation (AC-55). Synchronous reads,
                    // no await between the question and the verdict's effect.
                    let thermal = diagnostics?.thermal.current ?? .nominal
                    let allowed = thermalPolicy?.allowSettlingDecode(
                        thermal: thermal, activeSettlingDecodes: settlingRuns.count) ?? true
                    if allowed {
                        // D-024: a batch decode SURVIVES the next utterance —
                        // its ticket moves to the settling table, stamped with
                        // the audio it was fed.
                        settlingRuns[old.utterance] = Settling(
                            run: old.run, at: time(old.startFrames + old.fedFrames),
                            utteranceSpan: old.utteranceSpan, settleSpan: old.settleSpan)
                        diagnostics?.noteSettlingDecodes(count: settlingRuns.count)
                    } else {
                        // The refusal (AC-56): loud and exactly once — a named
                        // failure on the utterance, one health event, spans
                        // ended here (one grave, every path). The ticket died
                        // above; the cancel is the optimisation, as always.
                        publish(.failed(.declinedUnderThermalPressure,
                                        utterance: old.utterance,
                                        at: time(old.startFrames + old.fedFrames)))
                        diagnostics?.noteSettlingRefusal(
                            utterance: old.utterance, thermal: thermal)
                        endSpans(utteranceSpan: old.utteranceSpan, settleSpan: old.settleSpan)
                        await old.run.cancel()
                    }
                } else {
                    // D-021 ruling 1, unchanged for streaming engines: the
                    // new utterance retires the old one; ticket dead first.
                    // Its spans end HERE — found by the first field session:
                    // this branch dropped them, and Instruments closed the
                    // orphans at recording-stop, inflating every statistic.
                    endSpans(utteranceSpan: old.utteranceSpan, settleSpan: old.settleSpan)
                    await old.run.cancel()
                }
            }
            let utterance = nextUtterance
            nextUtterance += 1
            do {
                let run = try await engine.openRun(format: config.format)
                // Reentrancy law: stop() may have run while we awaited.
                guard !isStopped else { await run.cancel(); return }
                active = Active(
                    utterance: utterance, run: run, startFrames: at.frames,
                    utteranceSpan: diagnostics?.signposts.begin("session.utterance"))
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
            // The settle span: "no more audio" until the final lands — the
            // pause a user would feel (AC-45).
            active?.settleSpan = diagnostics?.signposts.begin("session.settle")
            await current.run.finishAudio()

        case .dropped:
            break   // the pump's honesty about lost sound; not text business
        }
    }

    // MARK: - engine updates (the ticket's door)

    private func handleUpdate(_ update: TranscriptionUpdate, utterance: Int) {
        // THE TICKET (AC-25, D-019, amended by D-024): checked in the same
        // actor step that can retire it. A live ticket is either the run
        // being fed or a settling batch decode; everything else is dead, and
        // a dead utterance's words stop at this line.
        let at: AudioTime
        if let current = active, current.utterance == utterance {
            // D-021 ruling 2: stamped with the audio already fed to this run.
            at = time(current.startFrames + current.fedFrames)
        } else if let settling = settlingRuns[utterance] {
            at = settling.at               // fixed when its audio completed
        } else {
            return                         // the dead ticket's door
        }

        switch update {
        case .partial(let text):
            publish(.partial(text, utterance: utterance, at: at))
        case .final(let text):
            publish(.final(text, utterance: utterance, at: at))
            retire(utterance)              // after the final: nothing, ever (AC-28)
        case .failed(let failure):
            publish(.failed(failure, utterance: utterance, at: at))
            retire(utterance)              // failure ends the utterance, not the session (AC-29)
        }
    }

    /// Ends an utterance's ticket wherever it lives — one funnel, no copies.
    /// The funnel also closes the utterance's Instruments spans: one grave,
    /// one place where every story ends.
    private func retire(_ utterance: Int) {
        if let current = active, current.utterance == utterance {
            endSpans(utteranceSpan: current.utteranceSpan, settleSpan: current.settleSpan)
            active = nil
        }
        if let settled = settlingRuns.removeValue(forKey: utterance) {
            endSpans(utteranceSpan: settled.utteranceSpan, settleSpan: settled.settleSpan)
            diagnostics?.noteSettlingDecodes(count: settlingRuns.count)
        }
    }

    private func endSpans(utteranceSpan: PipelineSignposter.Span?,
                          settleSpan: PipelineSignposter.Span?) {
        guard let signposts = diagnostics?.signposts else { return }
        if let settleSpan { signposts.end(settleSpan) }
        if let utteranceSpan { signposts.end(utteranceSpan) }
    }

    private func publish(_ event: TranscriptEvent) {
        broadcast.publish(event)
    }

    private func time(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: config.format.sampleRate)
    }
}
