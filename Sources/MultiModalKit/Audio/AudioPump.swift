/// The one bridge between the real-time audio world and Swift concurrency
/// (SPEC AC-9, AC-10).
///
/// The microphone thread may never wait: no locks, no allocation, no `await`.
/// So it only ever writes into the ring. The pump is the other side of that
/// crossing — a single long-lived structured task that, every poll interval of
/// **injected** clock time, drains the ring, cuts the frames into fixed-size
/// chunks (AC-17), asks the VAD about each chunk, and publishes events to
/// every listener (AC-20).
///
/// It is the ONLY reader of the ring, and it holds the ONLY clock. Everything
/// else in the package stays pure.
///
/// Event semantics (ruled in D-013):
/// - `speechStarted` is announced BEFORE the pre-roll chunks it explains,
///   even though those chunks carry earlier moments.
/// - `speechEnded` carries the moment the decision was made — the end of the
///   chunk that spent the hangover, not the moment the sound stopped.
/// - the quiet tail inside the hangover is published: it belongs to the
///   utterance, and a recogniser wants it.
/// - `dropped` points at the beginning of the gap, not at the recovery.
public actor AudioPump<C: Clock> where C.Duration == Duration {
    public struct Config: Sendable {
        /// Frames per second of the captured audio.
        public var sampleRate: Double
        /// How often the pump wakes to drain the ring.
        public var pollInterval: Duration
        /// Frames in one chunk — the unit the VAD judges (960 = 20 ms @ 48 kHz).
        public var chunkFrames: Int
        /// Chunks kept in hand so the start of a word survives (D-009).
        public var preRollChunks: Int
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int

        public init(
            sampleRate: Double = 48_000,
            pollInterval: Duration = .milliseconds(10),
            chunkFrames: Int = 960,
            preRollChunks: Int = 2,
            listenerBufferCapacity: Int = Broadcast<AudioEvent>.defaultBufferCapacity
        ) {
            self.sampleRate = sampleRate
            self.pollInterval = pollInterval
            self.chunkFrames = chunkFrames
            self.preRollChunks = preRollChunks
            self.listenerBufferCapacity = listenerBufferCapacity
        }
    }

    /// Why the pump woke up: the poll came due, or somebody asked it to stop.
    private enum Wake: Sendable {
        case poll
        case stopped
    }

    private let consumer: AudioRingConsumer
    private let clock: C
    private let config: Config
    private let broadcast: Broadcast<AudioEvent>
    private let stopSignal = StopSignal()

    private var vad: any VoiceActivityDetecting
    /// Drain space, allocated once — never inside the loop.
    private var scratch: [Float]
    /// Frames of sound that have already become chunks (or gaps). Audio time.
    private var framesConsumed = 0
    /// Frames read but not yet a whole chunk. Carried, never padded.
    private var carry: [Float] = []
    /// The last chunks heard while quiet — the run-up to a word (D-009).
    private var preRoll: [AudioChunk] = []
    private var isSpeaking = false
    private var isRunning = false
    private var isStopped = false

    public init(
        consumer: AudioRingConsumer,
        vad: any VoiceActivityDetecting,
        clock: C,
        config: Config = Config()
    ) {
        self.consumer = consumer
        self.vad = vad
        self.clock = clock
        self.config = config
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
        self.scratch = [Float](repeating: 0, count: consumer.capacity)
        self.carry.reserveCapacity(consumer.capacity + config.chunkFrames)
    }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<AudioEvent>.Listener {
        broadcast.listen()
    }

    /// Runs the pump until `stop()` is called or the task is cancelled.
    /// One task, structured, sleeping only on the injected clock.
    public func run() async {
        guard !isRunning, !isStopped else { return }
        isRunning = true

        while !isStopped && !Task.isCancelled {
            let wake = await waitForPollOrStop(until: clock.now.advanced(by: config.pollInterval))
            // Re-check after the await: stop() may have run while we waited.
            if wake == .stopped || isStopped || Task.isCancelled { break }
            drainOnce()
        }

        isRunning = false
        broadcast.finish()
    }

    /// Ends the pump at once: every listener's stream finishes, and the loop
    /// wakes immediately even though it is parked on the clock (D-014).
    public func stop() {
        isStopped = true
        stopSignal.signal()
        broadcast.finish()
    }

    /// Waits for whichever comes first: the next poll, or the stop signal.
    ///
    /// Two children, one scope, first result wins, loser cancelled — the same
    /// race-then-cancel shape as a barge-in. Both children are born inside
    /// this function's own task tree, so neither can outlive it: cancellation
    /// is the optimisation, structure is the guarantee.
    ///
    /// `nonisolated` on purpose: the actor must NOT be held while waiting, or
    /// `stop()` could never get in to change anything.
    private nonisolated func waitForPollOrStop(until deadline: C.Instant) async -> Wake {
        await withTaskGroup(of: Wake.self) { group in
            group.addTask { [clock] in
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                    return .poll
                } catch {
                    return .stopped   // cancelled while parked
                }
            }
            group.addTask { [stopSignal] in
                await stopSignal.wait()
                return .stopped
            }

            let first = await group.next() ?? .stopped
            group.cancelAll()         // the loser is cancelled, never abandoned
            return first
        }
    }

    /// How many events this listener missed because it read too slowly.
    public func droppedEvents(for listenerID: Int) -> Int {
        broadcast.droppedEvents(for: listenerID)
    }

    // MARK: - one poll

    private func drainOnce() {
        var framesRead = 0
        let framesDropped = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
            let result = consumer.read(into: buffer)
            framesRead = result.framesRead
            return result.framesDropped
        }

        if framesDropped > 0 {
            // The gap, stamped where it begins. A hole also breaks the carry:
            // those leftover frames are no longer next to what follows.
            publish(.dropped(frames: framesDropped, at: time(framesConsumed)))
            framesConsumed += framesDropped
            carry.removeAll(keepingCapacity: true)
        }

        guard framesRead > 0 else { return }
        carry.append(contentsOf: scratch[0..<framesRead])

        while carry.count >= config.chunkFrames {
            let samples = Array(carry.prefix(config.chunkFrames))
            carry.removeFirst(config.chunkFrames)
            judge(AudioChunk(samples: samples, start: time(framesConsumed)))
            framesConsumed += config.chunkFrames
        }
    }

    private func judge(_ chunk: AudioChunk) {
        let transition = chunk.samples.withUnsafeBufferPointer { vad.process($0) }

        switch transition {
        case .speechStarted:
            isSpeaking = true
            publish(.speechStarted(at: chunk.start))
            for held in preRoll { publish(.audioSegment(held)) }
            preRoll.removeAll(keepingCapacity: true)
            publish(.audioSegment(chunk))

        case .speechEnded:
            publish(.audioSegment(chunk))
            isSpeaking = false
            publish(.speechEnded(at: time(chunk.start.frames + chunk.frameCount)))
            preRoll.removeAll(keepingCapacity: true)

        case nil:
            if isSpeaking {
                publish(.audioSegment(chunk))
            } else {
                preRoll.append(chunk)
                if preRoll.count > config.preRollChunks { preRoll.removeFirst() }
            }
        }
    }

    private func publish(_ event: AudioEvent) {
        broadcast.publish(event)
    }

    private func time(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: config.sampleRate)
    }
}
