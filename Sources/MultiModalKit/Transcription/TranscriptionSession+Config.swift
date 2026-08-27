/// `TranscriptionSession`'s configuration — the audio shape it expects, the
/// utterance ceiling, and how far a listener may fall behind.
extension TranscriptionSession {
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
}
