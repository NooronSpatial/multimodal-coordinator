// THE LIBRARY SHIPS NO POLICY (4z, SPEC §193/8, AC-275; D-027, D-108).
//
// Two of Ryad's apps confirm a model-initiated write two different ways.
// Aura (§172a): the tool answers "needs confirmation", the mind ASKS, and
// the next turn's "yes" calls the tool again, confirmed. Emberleaf
// (D-077 there): the tool ACTS and says what it did; an undo tool
// reverses it. Neither needs anything from this library beyond the
// contract — no confirmation flag, no permission, no second seam — and
// these two rows are the proof, written on the scripted mind so they
// run on every machine.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

@Suite("4z · both callers' policies are buildable on top of the contract (AC-275)",
       .timeLimit(.minutes(1)))
struct ToolPolicyTests {

    // MARK: Aura — confirmation as a spoken turn

    /// The app's own rule: a write with `confirmed` absent answers a
    /// question and changes nothing; the same call with `confirmed: true`
    /// changes the plan. The mind carries the question in words; the
    /// library carries nothing.
    @Test("Aura: the tool asks, the mind speaks the question, the next turn's yes writes — one write")
    func confirmationIsASpokenTurn() async throws {
        let sessionMinutes = Mutex(40)
        let shorten = ReplyTool(
            name: "shorten_session",
            description: "Shorten today's session.",
            parameters: [
                ToolParameter(name: "by_minutes", description: "how many minutes less", kind: .integer),
                ToolParameter(name: "confirmed", description: "true once the person has said yes", kind: .boolean, isRequired: false)
            ]) { arguments in
                let minutes = try arguments.integer("by_minutes")
                guard arguments.has("confirmed"), try arguments.boolean("confirmed") else {
                    return "needs confirmation: shortening today's session by \(minutes) minutes — ask the person to say yes"
                }
                sessionMinutes.withLock { $0 -= minutes }
                return "done: the session is now \(sessionMinutes.withLock { $0 }) minutes"
            }
        // Turn 1: the model calls without confirmation and speaks the question.
        // Turn 2: the person said yes; the model calls again, confirmed.
        let generator = ScriptedReplyGenerator(plans: [
            .callsTool(ToolScript(name: "shorten_session", arguments: ["by_minutes": 10])),
            .callsTool(ToolScript(name: "shorten_session", arguments: ["by_minutes": 10, "confirmed": true]))
        ], tools: ToolTable([shorten]))

        let asked = try await generator.reply(to: ReplyContext(transcript: "make it shorter"))
        #expect(asked.text.hasPrefix("needs confirmation"), "the mind speaks the tool's question: \(asked.text)")
        #expect(sessionMinutes.withLock { $0 } == 40, "nothing changed on the question")

        let confirmed = try await generator.reply(to: ReplyContext(
            transcript: "yes", history: [ConversationTurn(said: "make it shorter", replied: asked.text)]))
        #expect(confirmed.text == "done: the session is now 30 minutes")
        #expect(sessionMinutes.withLock { $0 } == 30, "one write, on the confirmed call")
    }

    // MARK: Emberleaf — act at once, undo beside it

    /// The app's own rule: the tool writes and says so; the app keeps an
    /// undo stack; `undo_last` is a tool like any other. The library sees
    /// three ordinary calls.
    @Test("Emberleaf: the tool acts and says what it did; undo_last reverses it — the library sees three calls")
    func actAtOnceWithUndo() async throws {
        struct Entry: Equatable { let kg: Double }
        let entries = Mutex<[Entry]>([])
        let undoStack = Mutex<[@Sendable () -> Void]>([])
        let logWeight = ReplyTool(
            name: "log_weight",
            description: "Record today's body weight.",
            parameters: [ToolParameter(name: "kg", description: "kilograms", kind: .number)]) { arguments in
                let kg = try arguments.number("kg")
                let entry = Entry(kg: kg)
                entries.withLock { $0.append(entry) }
                undoStack.withLock { $0.append { entries.withLock { $0.removeAll { $0 == entry } } } }
                return "logged \(kg) kg"
            }
        let undoLast = ReplyTool(name: "undo_last", description: "Undo the last change.") { _ in
            guard let undo = undoStack.withLock({ $0.popLast() }) else { return "nothing to undo" }
            undo()
            return "undone"
        }
        let generator = ScriptedReplyGenerator(plans: [
            .callsTool(ToolScript(name: "log_weight", arguments: ["kg": 83.5])),
            .callsTool(ToolScript(name: "undo_last")),
            .callsTool(ToolScript(name: "undo_last"))
        ], tools: ToolTable([logWeight, undoLast]))

        #expect(try await generator.reply(to: ReplyContext(transcript: "log eighty-three and a half")).text == "logged 83.5 kg")
        #expect(entries.withLock { $0 } == [Entry(kg: 83.5)], "acted at once")
        #expect(try await generator.reply(to: ReplyContext(transcript: "undo that")).text == "undone")
        #expect(entries.withLock { $0 }.isEmpty, "reversed by the app's own undo")
        #expect(try await generator.reply(to: ReplyContext(transcript: "undo again")).text == "nothing to undo")
    }
}
