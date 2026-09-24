// `ConversationMemoryTests`, continued: the memory carries what ran (5b —
// AC-311, D-116 F-3 A, D-119 F-14 A).
//
// Before 5b an exchange was two strings. A re-seed then replayed a turn in
// which `log_weight` ran as the assistant's prose, and the mind learned to
// answer "Logged 12 kg" without calling anything (SPEC §207). These rows
// are the memory's half of the cure: it keeps the tools a turn used, it
// keeps an act even when no word followed it, and it counts what a replay
// of them costs.

import MultiModalKit
import Testing

extension ConversationMemoryTests {

    /// `log_weight` answered — the use a re-seed must replay as a call.
    static let logged = ToolUse(name: "log_weight", arguments: ["kg": 84],
                                outcome: ToolCallOutcome(result: .success("Logged 84 kg.")))

    @Test("an exchange in which a tool ran keeps what ran (AC-311)")
    func anExchangeKeepsItsTools() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "log 84 kilos", replied: "Logged.", tools: [Self.logged]))
        #expect(memory.turns.first?.tools == [Self.logged],
                "the name, the arguments and the outcome, whole")
    }

    @Test("an exchange with no tool is kept exactly as before (AC-311)")
    func anExchangeWithoutToolsIsUnchanged() {
        var memory = ConversationMemory()
        memory.record(ConversationTurn(said: "  what is Swift? ", replied: "A language. "))
        #expect(memory.turns == [ConversationTurn(said: "what is Swift?", replied: "A language.")])
        #expect(memory.turns.first?.tools.isEmpty == true)
        #expect(memory.characters == "what is Swift?".count + "A language.".count,
                "the budget of a turn with no tool is the words, as it always was")
    }

    /// D-119 F-14 A. The model called `log_weight`, the weight was logged,
    /// and the mind said nothing. Refused, the act would vanish from the
    /// conversation — the failure 5b exists to end, from the other side.
    @Test("a turn where a tool ran and the mind said nothing is kept: the act is the answer (D-119)")
    func aSilentActIsKept() {
        var memory = ConversationMemory()
        let kept = memory.record(ConversationTurn(said: "log 84 kilos", replied: "", tools: [Self.logged]))
        #expect(kept, "an act is an answer")
        #expect(memory.turns == [ConversationTurn(said: "log 84 kilos", replied: "", tools: [Self.logged])])
    }

    @Test("a turn with neither words nor a tool is still refused (4r's rule, unchanged)")
    func silenceWithoutAnActIsStillRefused() {
        var memory = ConversationMemory()
        let kept = memory.record(ConversationTurn(said: "log 84 kilos", replied: "  ", tools: []))
        #expect(!kept)
        #expect(memory.isEmpty)
    }

    /// Stated with D-119, from D-092: the memory is priced by the
    /// character because a replay costs by the character, and a replayed
    /// tool output is characters — up to `ToolTable.answerCap` of them.
    @Test("a tool's record counts against the budget (D-119, from D-092)")
    func aToolCountsAgainstTheBudget() {
        let turn = ConversationTurn(said: "ab", replied: "cd", tools: [Self.logged])
        // log_weight + {"kg":84} + Logged 84 kg.
        #expect(Self.logged.characters == "log_weight".count + #"{"kg":84}"#.count + "Logged 84 kg.".count)
        #expect(turn.characters == 4 + Self.logged.characters)

        // Room for two plain exchanges — not for one plain and one that
        // used a tool: the budget sees the tool and drops the oldest.
        var memory = ConversationMemory(maxTurns: 8, maxCharacters: 10)
        memory.record(ConversationTurn(said: "q1", replied: "a1"))
        memory.record(ConversationTurn(said: "q2", replied: "a2", tools: [Self.logged]))
        #expect(memory.turns.map(\.said) == ["q2"], "the tool's words were counted, so the oldest went")
    }
}
