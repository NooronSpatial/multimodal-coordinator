/// `TurnCoordinator` — the configuration it is built with: the buffer
/// size, the reply gate, the ledger bound, and the barge window.

extension TurnCoordinator {
    public struct Config: Sendable {
        /// Events a listener may fall behind by before the oldest is dropped.
        public var listenerBufferCapacity: Int
        /// The reply gate (AC-81, D-037 F-3): how long the floor must stay
        /// yielded after a final before the generator opens. An onset during
        /// the gate kills the pending reply silently — "the utterance ended"
        /// is a weaker fact than "the user is done". Mechanism here, the
        /// NUMBER with the app (D-027). Zero = byte-for-byte 4a. A non-zero
        /// gate needs the clocked initializer.
        public var replyGate: Duration
        /// How many pieces of one thought the ledger keeps (AC-85,
        /// D-040 F-4). Bounded because F-2 keeps a FAILED turn's words:
        /// without a bound, an oversized prompt could fail, keep its
        /// words, and fail again — wedged forever. The number is the
        /// app's (D-027); this default is a starting point, not a law.
        public var maxContextPieces: Int
        /// THE BARGE WINDOW (4k, D-071): while the assistant is SPEAKING, an
        /// onset must persist this long — in audio time — before it may kill
        /// the reply.
        ///
        /// It exists because the assistant hears itself. With the speaker
        /// shield on, its own cancelled reply still crosses the gate, and
        /// across six field sessions the leak and real speech separate
        /// perfectly by DURATION and not at all by level (INSTRUMENTS §43):
        ///
        ///     echo?    339 – 520 ms      peak 0.022 – 0.281
        ///     speech   939 – 3100 ms     peak 0.084 – 0.398
        ///
        /// D-060 F-1 rejected raising the gate while speaking because the
        /// two cannot be told apart BY LEVEL. That ruling is confirmed —
        /// this measures the other axis.
        ///
        /// **Not D-036's window returning.** That one gated TRANSCRIPTION
        /// and clipped speech ("Riyadh" → "Riyat"). This clips nothing:
        /// audio reaches the transcriber unchanged and only the KILL
        /// decision waits.
        ///
        /// **Zero by default**, because a library default is a policy claim
        /// (D-027; D-060 F-4 made the same correction for the shield). A
        /// device whose canceller removes system-wide output — macOS (§39) —
        /// wants none of this. `BargeWindow.measured` is the number for an
        /// app that does.
        public var bargeWindow: Duration
        /// HOW MANY PAST EXCHANGES THE MIND MAY SEE (4r, F-3 = C).
        /// A sanity cap after D-092; the budget below is what bites.
        public var maxMemoryTurns: Int
        /// AND HOW MANY CHARACTERS THEY MAY TOTAL — the second bound,
        /// because turns are wildly unequal and the older mind has a hard
        /// ceiling a count alone cannot protect (AC-116, AC-199).
        ///
        /// **Both defaults are MEASURED now** (D-092, INSTRUMENTS §58b):
        /// ~0.68 ms of felt pause and ~0.40 MB of transient memory per
        /// character on the phone this project targets. 600 characters is
        /// ~408 ms and ~243 MB. Set `maxMemoryTurns` to 0 and the memory
        /// is genuinely off; the app owns both numbers (D-027).
        public var maxMemoryCharacters: Int

        public init(
            listenerBufferCapacity: Int = Broadcast<TurnEvent>.defaultBufferCapacity,
            replyGate: Duration = .zero,
            maxContextPieces: Int = 16,
            bargeWindow: Duration = .zero,
            maxMemoryTurns: Int = 8,
            maxMemoryCharacters: Int = 600
        ) {
            self.listenerBufferCapacity = listenerBufferCapacity
            self.replyGate = replyGate
            self.maxContextPieces = maxContextPieces
            self.bargeWindow = bargeWindow
            self.maxMemoryTurns = maxMemoryTurns
            self.maxMemoryCharacters = maxMemoryCharacters
        }
    }
}
