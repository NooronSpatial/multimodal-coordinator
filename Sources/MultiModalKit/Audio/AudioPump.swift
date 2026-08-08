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
/// RED STUB — public surface only; behavior lands with the green commit.
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

    let consumer: AudioRingConsumer
    let clock: C
    let config: Config
    var vad: EnergyVAD

    public init(
        consumer: AudioRingConsumer,
        vad: EnergyVAD,
        clock: C,
        config: Config = Config()
    ) {
        self.consumer = consumer
        self.vad = vad
        self.clock = clock
        self.config = config
    }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<AudioEvent>.Listener {
        Broadcast<AudioEvent>.Listener(id: 0, events: AsyncStream { $0.finish() })
    }

    /// Runs the pump until `stop()` is called or the task is cancelled.
    /// One task, structured, sleeping only on the injected clock.
    public func run() async {}

    /// Ends the loop and finishes every listener's stream (AC-18).
    public func stop() {}

    /// How many events this listener missed because it read too slowly.
    public func droppedEvents(for listenerID: Int) -> Int {
        _ = listenerID
        return 0
    }
}
