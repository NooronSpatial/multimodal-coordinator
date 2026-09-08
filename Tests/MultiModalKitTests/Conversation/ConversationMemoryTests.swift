import MultiModalKit
import Testing

/// THE MEMORY'S RULES, PROVEN SYNCHRONOUSLY (4r, D-088, AC-191..AC-194).
///
/// No clock, no actor, no tasks — the ledger's precedent, for the ledger's
/// reason: bounds that are raced for are bounds nobody can defend. Every
/// fact here is a value in and a value out.
///
/// What this suite does NOT cover is where the coordinator calls `record`.
/// That is a pipeline question with its own tests; these are the rules the
/// type owes whoever calls it.
@Suite(.timeLimit(.minutes(1)))
struct ConversationMemoryTests {

    static func exchange(_ index: Int, size: Int = 1) -> ConversationTurn {
        ConversationTurn(said: String(repeating: "q", count: size) + "\(index)",
                         replied: String(repeating: "a", count: size) + "\(index)")
    }

    // MARK: - both halves, or nothing (AC-192)

    /// Fact 1. **An answer with no question is not kept.** It invites the
    /// mind to invent the question, which is worse than remembering
    /// nothing at all.
    @Test("an exchange with no question is not recorded")
    func anAnswerWithoutAQuestionIsNotKept() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "", replied: "Swift is a language."))
        #expect(memory.isEmpty)
    }

    /// Fact 2. **A question with no answer is not kept either** — and this
    /// is the case the pipeline really produces: the reply stream can end
    /// with zero tokens, the mind choosing silence. The person's words are
    /// still in the ledger's care; they are not an EXCHANGE.
    @Test("an exchange the mind answered with silence is not recorded")
    func aQuestionWithoutAnAnswerIsNotKept() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "what is Swift?", replied: ""))
        #expect(memory.isEmpty)
    }

    /// Fact 3. Whitespace is not words — the ledger's own rule, met again,
    /// because a detokenizer can yield spaces and nothing else.
    @Test("whitespace on either side is not an exchange")
    func whitespaceIsNotWords() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "  \n ", replied: "Rome."))
        memory.record(ConversationTurn(said: "which city?", replied: " \t"))
        #expect(memory.isEmpty)
    }

    /// Fact 4. **The halves are never joined.** F-1 = B exists because a
    /// flat string loses who said what; a memory that concatenated its two
    /// sides would give the seam back exactly the loss it was widened to
    /// avoid (AC-191).
    @Test("the person's words and the mind's stay apart")
    func theHalvesStayApart() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "who made it?", replied: "Apple did."))
        #expect(memory.count == 1)
        #expect(memory.turns.first?.said == "who made it?")
        #expect(memory.turns.first?.replied == "Apple did.")
    }

    // MARK: - the depth bound (F-3 = C, first limit)

    /// Fact 5. Past the depth, the OLDEST exchange goes — and what remains
    /// is a suffix of the conversation, never a selection with a hole in
    /// it. A hole would hide the exchange the current question is most
    /// likely to refer to.
    @Test("past the depth, the oldest whole exchange is dropped")
    func theDepthDropsTheOldest() {
        var memory = ConversationMemory(maxTurns: 3, maxCharacters: 100_000)
        for index in 1...5 { memory.record(Self.exchange(index)) }

        #expect(memory.count == 3)
        #expect(memory.turns.map(\.said) == ["q3", "q4", "q5"])
    }

    // MARK: - the budget bound (F-3 = C, second limit)

    /// Fact 6 — **THE ONE THAT EARNS THE SECOND BOUND.** The depth is
    /// generous and untouched; the CHARACTERS are what bite. A memory with
    /// only a turn count would have kept all six of these and handed the
    /// Apple mind a prompt past its measured 4096-token ceiling (AC-116).
    @Test("the budget bites while the depth still has room")
    func theBudgetBitesFirst() {
        var memory = ConversationMemory(maxTurns: 50, maxCharacters: 30)
        for index in 1...6 { memory.record(Self.exchange(index, size: 5)) }   // 12 each

        #expect(memory.count == 2, "30 characters holds two 12-character exchanges")
        #expect(memory.characters <= 30)
        #expect(memory.turns.last?.said.hasSuffix("6") == true, "the newest is always kept")
    }

    /// Fact 7. Whole exchanges leave, never halves. The bound is measured
    /// in characters and paid in EXCHANGES — trimming a reply mid-sentence
    /// to fit would produce exactly the half-turn Fact 1 refuses.
    @Test("the budget is paid in whole exchanges")
    func theBudgetNeverSplitsAnExchange() {
        var memory = ConversationMemory(maxTurns: 50, maxCharacters: 30)
        for index in 1...6 { memory.record(Self.exchange(index, size: 5)) }

        for turn in memory.turns {
            #expect(turn.said.count == 6 && turn.replied.count == 6,
                    "\"\(turn.said)\"/\"\(turn.replied)\" was trimmed to fit")
        }
    }

    /// Fact 8 — **AN OVERSIZED EXCHANGE IS KEPT, ALONE, OVER BUDGET**
    /// (F-9 = B, D-096 — reversing D-088's cliff).
    ///
    /// The first rule here was the opposite: an exchange too large to fit
    /// alone EMPTIED the memory, a "hard budget" argued for on the older
    /// mind's ceiling. The field then produced it: the Apple mind answered
    /// in ~1,500 characters, the cliff fired, and "what is the capital?"
    /// was answered as if the conversation had never happened
    /// (INSTRUMENTS §61). A bound that forgets silently is worse than a
    /// bound that is exceeded by one exchange and says so.
    @Test("an exchange too large to fit alone is kept alone, over budget")
    func anOversizedExchangeIsKeptAlone() {
        var memory = ConversationMemory(maxTurns: 50, maxCharacters: 40)
        memory.record(Self.exchange(1, size: 5))
        #expect(memory.count == 1)

        let big = ConversationTurn(said: String(repeating: "x", count: 100),
                                   replied: "and then some")
        #expect(memory.record(big), "the newest exchange is never the one the budget drops")
        #expect(memory.count == 1, "the older exchange went; the oversized one stands alone")
        #expect(memory.turns.first?.replied == "and then some")
        #expect(memory.characters > memory.maxCharacters,
                "exceeded by exactly one exchange — the honest overshoot D-096 allows")
    }

    /// Fact 8b. **The overshoot lasts one exchange.** The next one cannot
    /// fit beside the oversized one, so the oversized one is evicted — the
    /// bound is back under its number, and nothing was forgotten in
    /// silence: the long answer was there for the turn that needed it.
    @Test("the next exchange evicts the oversized one, and the bound holds again")
    func theNextExchangeEvictsTheOversizedOne() {
        var memory = ConversationMemory(maxTurns: 50, maxCharacters: 40)
        memory.record(ConversationTurn(said: String(repeating: "x", count: 100),
                                       replied: "and then some"))
        memory.record(Self.exchange(2, size: 5))          // 12 characters
        #expect(memory.count == 1)
        #expect(memory.turns.first?.said == "qqqqq2")
        #expect(memory.characters <= memory.maxCharacters, "the bound holds again")
    }

    // MARK: - the interruption mark (F-2 = C, AC-193)

    /// Fact 9. A barged exchange is REMEMBERED AND MARKED. Losing the mark
    /// would let the mind say "as I explained" about a sentence the person
    /// heard half of; losing the exchange would lose the question they
    /// actually asked.
    @Test("an interrupted exchange is kept, and says so")
    func anInterruptedExchangeKeepsItsMark() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "tell me about Swift",
                                       replied: "Swift is a programming langu",
                                       interrupted: true))
        #expect(memory.turns.first?.interrupted == true)
        #expect(memory.turns.first?.replied == "Swift is a programming langu",
                "what was generated, not what was heard — the library cannot know the second")
    }

    /// Fact 10. An ordinary exchange is not marked. The flag has to MEAN
    /// something, so the default has to be false.
    @Test("a completed exchange carries no mark")
    func aCompletedExchangeIsNotMarked() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "hello", replied: "Hello there."))
        #expect(memory.turns.first?.interrupted == false)
    }

    // MARK: - the session boundary (F-4 = A)

    /// Fact 11. `clear()` ends the conversation — the Listen session
    /// closed, or the app asked. A boundary a person can SEE is the only
    /// kind they can trust.
    @Test("clearing forgets everything and stays usable")
    func clearingForgetsEverything() {
        var memory = ConversationMemory()
        for index in 1...3 { memory.record(Self.exchange(index)) }
        memory.clear()
        #expect(memory.isEmpty)
        #expect(memory.characters == 0)

        memory.record(Self.exchange(9))
        #expect(memory.count == 1, "a cleared memory is not a dead one")
    }

    /// Fact 13 — **THE SHIPPED BOUND, AND THE MEASUREMENT THAT SET IT**
    /// (AC-197/AC-198/AC-199, D-092, INSTRUMENTS §58b).
    ///
    /// The sweep on Ryad's phone found the cost linear in CHARACTERS —
    /// ~0.68 ms of felt pause and ~0.40 MB of transient memory each, three
    /// segments agreeing within 2.5%. So 600 characters is ~408 ms and
    /// ~243 MB, which is what this project ships.
    ///
    /// **The number this replaced is the reason this test is not
    /// decoration.** 4,000 was D-088's placeholder and extrapolates to
    /// +2,722 ms and +1,618 MB against the 1,269 MB of room that session
    /// had. It was a jetsam risk nobody had reached, because no
    /// conversation had yet run long enough to fill it. A default that
    /// dangerous should not be movable without meeting these lines.
    ///
    /// It also still clears the OLDER mind's ceiling with room to spare:
    /// Apple's was measured at 4096 tokens (AC-116), roughly 16,000
    /// characters for the whole window, and the past may claim 600.
    @Test("the shipped bound is the measured one, and it clears both limits")
    func theShippedBoundIsTheMeasuredOne() {
        let config = TurnCoordinator<ContinuousClock>.Config()
        #expect(config.maxMemoryCharacters == 600)
        #expect(config.maxMemoryTurns == 8)

        // The felt pause this buys, at the measured 0.68 ms per character.
        #expect(Double(config.maxMemoryCharacters) * 0.68 < 500,
                "a memory that costs half a second recreates the complaint it was added beside")
        // And the transient spike, at the measured 0.40 MB per character,
        // against the smallest headroom this app has been seen to have.
        #expect(Double(config.maxMemoryCharacters) * 0.40 < 400,
                "the prefill spike must stay far from the jetsam limit (D-079, §27)")
        #expect(config.maxMemoryCharacters * 4 <= 16_000,
                "and the past alone must not fill Apple's 4096-token window")

        // A bound configured and then not applied is the failure this
        // whole suite exists to catch.
        var memory = ConversationMemory(maxTurns: config.maxMemoryTurns,
                                        maxCharacters: config.maxMemoryCharacters)
        for index in 1...40 { memory.record(Self.exchange(index, size: 300)) }
        #expect(memory.count <= config.maxMemoryTurns)
        #expect(memory.characters <= config.maxMemoryCharacters)
    }

    /// Fact 13b — an ordinary exchange fits the shipped bound whole.
    ///
    /// This test was written when Fact 8 was a cliff, to show 600 kept it
    /// three times clear of the longest field exchange (~185 characters).
    /// D-096 removed the cliff, so it no longer guards against a wipe —
    /// it now pins the plainer fact that a real exchange is kept without
    /// the bound being exceeded at all.
    @Test("an ordinary exchange cannot reach the cliff at the shipped bound")
    func theCliffIsOutOfReachAtTheShippedBound() {
        var memory = ConversationMemory()
        let longestSeenInTheField = ConversationTurn(
            said: String(repeating: "q", count: 40),
            replied: String(repeating: "a", count: 145))
        #expect(longestSeenInTheField.characters == 185)
        let kept = memory.record(longestSeenInTheField)
        #expect(kept, "the longest real exchange must never wipe the conversation")
    }

    /// Fact 15. **A depth of zero is a memory switched off, not a crash.**
    ///
    /// The ledger refuses to be built that way and this does not, because
    /// the two mean different things: a ledger holding nothing loses the
    /// sentence being spoken now, while a memory holding nothing is just
    /// the conversation this library had before 4r. AC-197's baseline row
    /// is measured with exactly this.
    @Test("a depth of zero remembers nothing and says so")
    func zeroDepthIsAMemorySwitchedOff() {
        var memory = ConversationMemory(maxTurns: 0, maxCharacters: 4_000)
        #expect(memory.record(ConversationTurn(said: "q", replied: "a")) == false)
        #expect(memory.isEmpty)
    }

    /// Fact 14. `record` reports whether the exchange was TAKEN, because
    /// one caller cannot be correct without knowing (F-5 = A): the
    /// coordinator clears the ledger only for what the memory kept.
    @Test("record says whether the memory took the exchange")
    func recordReportsWhatItTook() {
        var memory = ConversationMemory(maxTurns: 4, maxCharacters: 40)
        #expect(memory.record(ConversationTurn(said: "q", replied: "a")) == true)
        #expect(memory.record(ConversationTurn(said: "q", replied: "")) == false,
                "half an exchange is refused, and the caller must be told")
        #expect(memory.record(ConversationTurn(
            said: String(repeating: "x", count: 100), replied: "y")) == true,
                "one that cannot fit alone is KEPT alone since D-096 — and so reported")
    }

    /// Fact 12. Value equality, so a test can compare two memories without
    /// reaching inside one.
    @Test("two memories holding the same conversation are equal")
    func equalityIsOverTheConversation() {
        var one = ConversationMemory(maxTurns: 4, maxCharacters: 500)
        var two = ConversationMemory(maxTurns: 4, maxCharacters: 500)
        for index in 1...3 {
            one.record(Self.exchange(index))
            two.record(Self.exchange(index))
        }
        #expect(one == two)

        two.record(Self.exchange(4))
        #expect(one != two)
    }
}
