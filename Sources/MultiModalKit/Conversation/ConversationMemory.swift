/// WHAT THE CONVERSATION SAID BEFORE THIS ONE (SPEC §150-155, D-088).
///
/// `TranscriptLedger` holds the pieces of *this* thought and forgets them
/// the moment the reply is fully spoken (D-040 F-2). This holds the
/// thoughts before it — the exchanges the mind is allowed to remember.
///
/// The two never overlap, and that is a rule and not a hope: a sentence
/// lives in the ledger **or** here, never in both, because a mind handed
/// the same words twice will answer them twice.
///
/// Deliberately pure, for the ledger's reason: no clock, no actor, no
/// tasks. Its whole suite runs synchronously, so the bounds below are
/// proven exactly rather than raced for.
///
/// RED skeleton: the shape without the judgment. Every rule below is a
/// failing test until GREEN wires it.
public struct ConversationMemory: Sendable, Equatable {
    /// How many past exchanges may be kept (F-3 = C, the first bound).
    public let maxTurns: Int
    /// How many characters all kept exchanges may total (F-3 = C, the
    /// second bound).
    ///
    /// Both exist because turns are wildly unequal: three long answers can
    /// outweigh twenty short ones, so a depth alone cannot protect the
    /// Apple mind's measured 4096-token ceiling (AC-116), and a budget
    /// alone can keep forty tiny turns and pay prefill for every one.
    ///
    /// The NUMBERS are the app's (D-027). These defaults are a starting
    /// point and are deliberately not ruled: AC-197 measures the felt
    /// pause at three depths on the phone, and D-088 leaves the default
    /// depth to that measurement.
    public let maxCharacters: Int

    /// Oldest first — the conversation in the order it happened.
    ///
    /// Always a SUFFIX of the conversation, never a selection with a hole
    /// in it: dropping from the middle would hide the exchange the current
    /// question is most likely to refer to.
    private var kept: [ConversationTurn] = []

    public init(maxTurns: Int = 6, maxCharacters: Int = 4000) {
        precondition(maxTurns > 0, "a memory that can hold nothing is not a bound, it is a bug")
        precondition(maxCharacters > 0, "same")
        self.maxTurns = maxTurns
        self.maxCharacters = maxCharacters
    }

    /// Records one finished exchange.
    ///
    /// **Both halves or nothing.** A question with no answer, or an answer
    /// with no question, is worse for a model than silence — it invites
    /// the mind to fill the gap. A turn the mind answered with zero tokens
    /// is therefore not an exchange and is not kept.
    public mutating func record(_ turn: ConversationTurn) {
        _ = turn
    }

    /// The exchanges the mind may see, oldest first.
    public var turns: [ConversationTurn] { kept }

    /// True when there is nothing to remember.
    public var isEmpty: Bool { kept.isEmpty }

    /// How many exchanges are held — the depth bound's observable side.
    public var count: Int { kept.count }

    /// Characters across every kept exchange — the budget's observable
    /// side, and the number an app tunes `maxCharacters` against.
    public var characters: Int { kept.reduce(0) { $0 + $1.characters } }

    /// Forgets the conversation (F-4 = A: the Listen session ended, or the
    /// app asked).
    public mutating func clear() {
        kept.removeAll(keepingCapacity: true)
    }
}

/// One finished exchange, with the two halves kept APART.
///
/// F-1 = B's whole argument in one type: a flat string is a lossy encoding
/// of who said what, and both real minds already have a role-tagged native
/// shape to map this onto — MLX's `Chat.Message`, Apple's per-turn
/// messages.
public struct ConversationTurn: Sendable, Equatable {
    /// What the person said.
    public let said: String
    /// What the mind produced — GENERATED, not necessarily heard (F-2 = C).
    public let replied: String
    /// The person cut this reply off.
    ///
    /// It is a mark, not a measurement. `SynthesisRun` reports `started`
    /// and `finished` and nothing between, so how much of `replied`
    /// reached the person's ears is not a fact this library owns. The mark
    /// is what stops the mind from saying "as I explained" about a
    /// sentence the person heard half of.
    public let interrupted: Bool

    public init(said: String, replied: String, interrupted: Bool = false) {
        self.said = said
        self.replied = replied
        self.interrupted = interrupted
    }

    /// What this exchange costs against `maxCharacters`.
    public var characters: Int { said.count + replied.count }
}
