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
/// Deliberately clockless: the 30-second ceiling (AC-26) is counted in FRAMES
/// of audio, and every event is stamped in audio time. Time lives in the
/// sound, not in a scheduler (D-011).
///
/// RED STUB — public surface only; behavior lands with the green commit.
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

    let engine: any TranscriptionEngine
    let config: Config

    public init(engine: any TranscriptionEngine, config: Config = Config()) {
        self.engine = engine
        self.config = config
    }

    /// Adds a listener. It hears everything published from now on (D-012).
    public func listen() -> Broadcast<TranscriptEvent>.Listener {
        Broadcast<TranscriptEvent>.Listener(id: 0, events: AsyncStream { $0.finish() })
    }

    /// Consumes audio events until the stream ends or `stop()` is called.
    /// Structured: every reader the session starts lives inside this call.
    public func run(events: AsyncStream<AudioEvent>) async {}

    /// Ends the session: open recognitions are cancelled, their tickets die,
    /// and every listener's stream finishes (AC-32).
    public func stop() {}
}
