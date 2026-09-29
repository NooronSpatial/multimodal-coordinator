// The `session` instrument (5b, AC-314, INSTRUMENTS §71): what one turn
// PREFILLS — the text the Apple model must read before it can say its
// first word — with a FRESH session every turn (every turn before 5b) and
// with the KEPT one (5b), over a conversation shaped like the diet app's
// coach: 5 100 characters of instructions, fifteen tools, a memory of
// four turns.
//
//   swift run bakeoff session [--turns=20] [--memory=4]
//
// CHARACTERS are counted on what this library HANDS the vendor: the
// instructions, each tool's declaration as the vendor's own schema (JSON),
// the remembered turns as the memory prices them (`ConversationTurn
// .characters`, D-092), and the new words. TOKENS are the vendor's own
// count (`SystemLanguageModel.tokenCount`, macOS 26.4) where it will say;
// on a Mac whose model is not ready it will not, and the table says so
// rather than guessing a ratio. A turn's OWN tool outputs are prefilled
// in both worlds alike, mid-answer, so they are in neither column.
//
// What this Mac cannot take is named, not estimated: the phone's
// first-token latency (AC-315, Ryad's gate).
import Foundation
import FoundationModels
import MultiModalKit

// MARK: - the conversation

/// The coach's rules — synthetic, sized to the diet app's 5 100 characters.
/// Characters are exact; tokens of repeated synthetic text are not the
/// coach's tokens, and the section says so.
func sessionInstructions(_ size: Int = 5_100) -> String {
    let rules = [
        "You are a friendly nutrition coach who speaks briefly, in one or two short sentences.",
        "When the person tells you what they ate or drank, call the matching logging tool before you answer.",
        "Never claim you logged, changed or deleted anything unless a tool answered that it did.",
        "When a tool refuses, say plainly what was not done and what the person can do instead.",
        "Answer questions about today's totals only from what the tools return, never from memory alone."
    ]
    var text = ""
    var index = 0
    while text.count < size {
        text += "Rule \(index + 1): \(rules[index % rules.count]) "
        index += 1
    }
    return String(text.prefix(size))
}

/// Fifteen tools, the diet app's count. Bodies answer at once; this
/// instrument measures what the model READS, not what a tool does.
func sessionTools() -> ToolTable {
    func number(_ name: String, _ words: String) -> ToolParameter {
        ToolParameter(name: name, description: words, kind: .number, isRequired: true)
    }
    func text(_ name: String, _ words: String) -> ToolParameter {
        ToolParameter(name: name, description: words, kind: .string, isRequired: true)
    }
    func tool(_ name: String, _ words: String, _ parameters: [ToolParameter]) -> ReplyTool {
        ReplyTool(name: name, description: words, parameters: parameters,
                  requiresConfirmation: false) { _ in "Done." }
    }
    return ToolTable([
        tool("log_weight", "Records today's body weight in the person's log.",
             [number("kg", "The weight in kilograms.")]),
        tool("log_food", "Records one food or drink the person had.",
             [text("item", "What they ate or drank, in their words."), number("grams", "How much, in grams.")]),
        tool("log_water", "Records water the person drank.", [number("ml", "How much, in millilitres.")]),
        tool("log_sleep", "Records last night's sleep.", [number("hours", "How long they slept, in hours.")]),
        tool("log_steps", "Records today's step count.", [number("steps", "The number of steps.")]),
        tool("log_mood", "Records how the person feels right now.", [number("score", "From 1 (low) to 5 (great).")]),
        tool("log_exercise", "Records one exercise session.",
             [text("kind", "What they did."), number("minutes", "For how long, in minutes.")]),
        tool("get_today", "Returns everything logged today, with totals.", []),
        tool("get_week", "Returns the last seven days, one line per day.", []),
        tool("get_goal", "Returns the person's current goals.", []),
        tool("set_goal", "Sets one daily goal.",
             [text("kind", "calories, protein, water or steps."), number("value", "The daily target.")]),
        tool("edit_entry", "Changes the amount of one logged entry.",
             [text("id", "The entry to change."), number("value", "The new amount.")]),
        tool("delete_entry", "Deletes one logged entry.", [text("id", "The entry to delete.")]),
        tool("undo_last", "Undoes the last thing that was logged.", []),
        tool("get_rules", "Returns the full coaching rulebook, for questions about how the coach works.", [])
    ])
}

/// One turn of the script: what the person said, the tool that ran (if
/// any), and what the mind answered.
struct SessionTurn {
    let said: String
    let use: ToolUse?
    let replied: String
}

func sessionScript(turns: Int) -> [SessionTurn] {
    (1...turns).map { number in
        switch number % 3 {
        case 1:
            let kg = 80 + Double(number % 7)
            return SessionTurn(
                said: "Log \(Int(kg)) kilos, please.",
                use: ToolUse(name: "log_weight", arguments: ["kg": .number(kg)],
                             outcome: ToolCallOutcome(result: .success("Logged \(Int(kg)) kg."))),
                replied: "Done — \(Int(kg)) kilos is in your log for today.")
        case 2:
            return SessionTurn(
                said: "I just had a coffee with milk.",
                use: ToolUse(name: "log_food", arguments: ["item": .string("coffee with milk"), "grams": .number(250)],
                             outcome: ToolCallOutcome(result: .success("Logged coffee with milk, 250 g."))),
                replied: "Logged your coffee with milk. That's your second drink this morning.")
        default:
            return SessionTurn(
                said: "How am I doing today?",
                use: nil,
                replied: "You're on track: two drinks, one weigh-in, and plenty of room for lunch.")
        }
    }
}

// MARK: - the vendor's view of a declaration

/// A tool's declaration as the vendor's schema — the same mapping as
/// `AppleToolAdapter.schema(for:)` (internal to the library, pinned by
/// `AppleToolTests+Schema`), mirrored here because an instrument cannot
/// reach internals. A band is left out: none of these declares one.
@available(macOS 26.0, *)
func sessionSchema(for tool: ReplyTool) throws -> GenerationSchema {
    let properties = tool.parameters.map { parameter in
        DynamicGenerationSchema.Property(
            name: parameter.name, description: parameter.description,
            schema: parameter.kind == .string
                ? DynamicGenerationSchema(type: String.self)
                : DynamicGenerationSchema(type: Double.self),
            isOptional: !parameter.isRequired)
    }
    return try GenerationSchema(root: DynamicGenerationSchema(name: tool.name, description: tool.description,
                                                              properties: properties),
                                dependencies: [])
}

// MARK: - the run

@available(macOS 26.0, *)
func runSession(_ arguments: [String]) async {
    let turns = sessionArgument("--turns=", in: arguments).flatMap(Int.init) ?? 20
    let bound = sessionArgument("--memory=", in: arguments).flatMap(Int.init) ?? 4
    let instructions = sessionInstructions()
    let tools = sessionTools()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var schemaCharacters = 0
    var schemas: [GenerationSchema] = []
    for tool in tools.tools {
        guard let schema = try? sessionSchema(for: tool),
              let json = try? encoder.encode(schema),
              let text = String(bytes: json, encoding: .utf8) else {
            print("could not render \(tool.name)'s schema"); exit(1)
        }
        schemas.append(schema)
        schemaCharacters += text.count
    }
    let fixed = instructions.count + schemaCharacters

    print("# bakeoff session — what one turn prefills, fresh and kept (INSTRUMENTS §71, 5b AC-314)\n")
    print("instructions: \(instructions.count) characters · tools: \(tools.tools.count), "
        + "\(schemaCharacters) characters of schema (JSON) · memory: \(bound) turns · turns: \(turns)")
    print("fixed part a fresh session pays every turn: \(fixed) characters\n")
    print("| turn | window | fresh session (before 5b) | kept session (5b) | saved |")
    print("|---:|---:|---:|---:|---:|")

    var memory = ConversationMemory(maxTurns: bound, maxCharacters: 1_000_000)
    var freshTotal = 0
    var keptTotal = 0
    var reseedAtTheBound = 0
    for (index, turn) in sessionScript(turns: turns).enumerated() {
        let number = index + 1
        let window = memory.characters
        let fresh = fixed + window + turn.said.count
        let kept = (number == 1 ? fixed : 0) + turn.said.count
        freshTotal += fresh
        keptTotal += kept
        if memory.count == bound { reseedAtTheBound = fresh }
        let saved = fresh == 0 ? 0 : 100 * (fresh - kept) / fresh
        print("| \(number) | \(memory.count) turns, \(window) ch | \(fresh) | \(kept) | \(saved) % |")
        memory.record(ConversationTurn(said: turn.said, replied: turn.replied, tools: turn.use.map { [$0] } ?? []))
    }
    print("| **all \(turns)** | | **\(freshTotal)** | **\(keptTotal)** | "
        + "**\(freshTotal == 0 ? 0 : 100 * (freshTotal - keptTotal) / freshTotal) %** |\n")
    print("a RE-SEED (a barge, a failure, the wall, a new conversation) pays what every pre-5b turn paid: "
        + "\(reseedAtTheBound) characters at a full memory of \(bound) turns.\n")

    await sessionTokens(instructions: instructions, schemas: schemas,
                        sample: sessionScript(turns: turns).first?.said ?? "")

    print("\nOWED — the number this Mac cannot take (AC-315, Ryad's gate): turn two's FIRST TOKEN on the phone,")
    print("with the same 5 100 characters and 15 tools. The characters above are what it no longer re-reads.")
    exit(0)
}

/// The vendor's own count, where it will say.
@available(macOS 26.0, *)
func sessionTokens(instructions: String, schemas: [GenerationSchema], sample: String) async {
    let model = SystemLanguageModel.default
    print("the vendor's tokens (SystemLanguageModel.tokenCount) — availability: \(model.availability)")
    guard #available(macOS 26.4, *) else {
        print("  NOT ASKED: tokenCount needs macOS 26.4; this Mac is older.")
        return
    }
    do {
        let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
        var schemaTokens = 0
        for schema in schemas { schemaTokens += try await model.tokenCount(for: schema) }
        let promptTokens = try await model.tokenCount(for: sample)
        print("  instructions: \(instructionTokens) tokens · 15 schemas: \(schemaTokens) tokens · "
            + "one utterance (\"\(sample)\"): \(promptTokens) tokens")
    } catch {
        print("  the vendor will not say here: \(error)")
    }
}

func sessionArgument(_ prefix: String, in arguments: [String]) -> String? {
    arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}
