/// The library's namesake (SPEC §31, D-030, D-031): the conversation loop
/// above the transcription spine. Consumes the audio and transcript streams
/// the pipeline already broadcasts, drives the reply and synthesis seams,
/// and publishes `TurnEvent`s.
///
/// SKELETON (red phase): types and shape only — the loop consumes its
/// inputs and transitions nothing. The suite committed alongside this file
/// fails on every behavioral assertion; the green commit wires the machine.
public actor TurnCoordinator {
    public struct Config: Sendable {
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int

        public init(listenerBufferCapacity: Int = Broadcast<TurnEvent>.defaultBufferCapacity) {
            self.listenerBufferCapacity = listenerBufferCapacity
        }
    }

    private let replyGenerator: any ReplyGenerating
    private let synthesizer: any SpeechSynthesizing
    private let config: Config
    private let broadcast: Broadcast<TurnEvent>

    private var state: TurnState = .idle
    private var isStopped = false

    public init(
        replyGenerator: any ReplyGenerating,
        synthesizer: any SpeechSynthesizing,
        config: Config = Config()
    ) {
        self.replyGenerator = replyGenerator
        self.synthesizer = synthesizer
        self.config = config
        self.broadcast = Broadcast(bufferCapacity: config.listenerBufferCapacity)
    }

    /// The current state, for late listeners: ask for NOW, then listen —
    /// events replay nothing (D-030, AC-67).
    public var currentState: TurnState { state }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<TurnEvent>.Listener {
        broadcast.listen()
    }

    /// Consumes both input streams until they end or `stop()` is called.
    public func run(
        audio: AsyncStream<AudioEvent>,
        transcripts: AsyncStream<TranscriptEvent>
    ) async {
        guard !isStopped else { return }
        // Skeleton: drain the inputs, decide nothing.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in audio {} }
            group.addTask { for await _ in transcripts {} }
        }
        broadcast.finish()
    }

    /// Ends the loop: every listener's stream finishes.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        broadcast.finish()
    }
}
