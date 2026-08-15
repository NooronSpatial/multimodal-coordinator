/// The turn seams (SPEC §31, D-029). The coordinator talks to THESE — never
/// to a model API, never to a speech framework. 4a ships scripted stages;
/// real engines arrive behind the same seams (4b/4c).

/// Where the conversation stands. Four states, one funnel, one table.
public enum TurnState: Sendable, Equatable {
    /// Nobody is speaking; the pipeline waits.
    case idle
    /// The user is speaking (or just paused; their final is not in yet).
    case listening
    /// The reply is being generated; nothing is audible yet.
    case thinking
    /// The reply is being spoken — the state follows the synthesizer's own
    /// report (D-029), never the coordinator's assumption.
    case speaking
}

/// The ways a turn really fails. A turn's failure ends the TURN, never the
/// coordinator (AC-65) — the next utterance starts the next turn clean.
public enum TurnFailure: Error, Sendable, Equatable {
    case generationFailed(String)
    case synthesisFailed(String)
    case transcriptionFailed(TranscriptionFailure)
    /// The platform took the audio away mid-turn — a call, Siri, a route
    /// that vanished (AC-94, D-042 F-3). It is a FAILURE, not a barge:
    /// the speaker did not interrupt, the system did, so `turnBarged`
    /// would be a lie and `listening` afterwards would claim an
    /// utterance that does not exist. Being a failure also means the
    /// speaker's words stay in the ledger — nothing answered them
    /// (D-040 F-2).
    case interrupted
}

/// What the coordinator publishes (AC-67). Every event carries its turn
/// number — the ticket made visible.
public enum TurnEvent: Sendable, Equatable {
    case stateChanged(TurnState, turn: Int)
    /// A reply token, as it is born. Apps may render the reply building up.
    case replyToken(String, turn: Int)
    /// The turn's reply was fully spoken. Terminal for that turn.
    case turnCompleted(turn: Int)
    /// The user interrupted this turn; a new one is already listening.
    case turnBarged(turn: Int)
    /// The turn died on a stage failure. Terminal for that turn.
    case turnFailed(TurnFailure, turn: Int)
}

// MARK: - the reply seam (F2 = A: a token stream, D-029)

/// What one reply generation can say back. Tokens as they are born, then
/// exactly one terminal update, then the stream ends.
public enum ReplyUpdate: Sendable, Equatable {
    case token(String)
    case finished
    case failed(String)
}

/// ONE reply — one final transcript in, a token stream out.
public protocol ReplyRun: Sendable {
    /// Single consumer: the coordinator.
    var updates: AsyncStream<ReplyUpdate> { get }
    /// Abandon the reply. A conformant generator ends `updates` without a
    /// terminal; a defiant one may still emit — which is why the turn
    /// ticket, not this call, is the guarantee (AC-62).
    func cancel() async
}

/// A factory for replies. The only thing the coordinator holds.
public protocol ReplyGenerating: Sendable {
    /// Opens one reply. Throws when generation cannot start at all.
    func openReply(to transcript: String) async throws -> any ReplyRun
}

// MARK: - the synthesis seam (F4 = A: state follows evidence, D-029)

/// What one spoken utterance reports. `started` is the evidence that sound
/// is audible — the coordinator's `speaking` state begins THERE.
public enum SynthesisUpdate: Sendable, Equatable {
    case started
    case finished
    case failed(String)
}

/// ONE spoken reply — tokens fed in as they arrive, evidence reported out.
public protocol SynthesisRun: Sendable {
    /// Single consumer: the coordinator.
    var updates: AsyncStream<SynthesisUpdate> { get }
    /// Hand the synthesizer the next token, in order.
    func feed(_ token: String) async
    /// No more tokens are coming — finish speaking what remains.
    func finishTokens() async
    /// Abandon the utterance mid-speech. Same contract as `ReplyRun.cancel`.
    func cancel() async
}

/// A factory for spoken utterances.
public protocol SpeechSynthesizing: Sendable {
    func openUtterance() async throws -> any SynthesisRun
}
