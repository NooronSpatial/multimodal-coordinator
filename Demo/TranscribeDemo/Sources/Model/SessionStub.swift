import MultiModalKit
import Observation

/// THE THROWAWAY TOOL'S ANSWER — one fixed session, owned by the demo
/// (4w, F-3 = C, D-101).
///
/// The spike rehearses Aura's "read today's session" (SPEC §168a) on
/// both real minds, and F-3 = C says the answer comes from a STUB the
/// demo owns: a fixed session with a readiness verdict. Fixed on purpose
/// — a phone run has to prove that the tool was CALLED and its words
/// came back through the model (AC-222/AC-223's phone halves), and only
/// an answer nobody could guess makes that proof readable off the log.
/// Nothing here is a training plan; Aura's logic decides those (D-101:
/// the user disposes), and this app is not Aura.
///
/// THE WORDS ARE THE APP'S (D-027). The library ships no name, no
/// description and no sentence for this tool — `ReplyTool` is a name, a
/// description and a function, and every string below is this demo's
/// policy, the way `spokenInstructions` is.
enum SessionStub {
    /// The name the model asks for. Exact-match on both minds
    /// (`ToolTable`), and the word the person says aloud — the sentence
    /// in `sentenceToSay` names it, because that is the only shape the
    /// spike measured working (AC-222's finding, INSTRUMENTS §67).
    static let name = "session"

    /// What the model is told the tool does. Short, because the spec is
    /// PREFILL on every turn while Tools is on (§58b's slope; AC-228
    /// prices it on the phone).
    static let description = "Read today's training session and the readiness verdict behind it."

    /// The answer, as ONE plain spoken paragraph. It is fed back to the
    /// model verbatim and the model's reply is SPOKEN, never read — so
    /// no list, no markdown, and the numbers are written as words. Why
    /// words: the model paraphrases this before the mouth reads it, and
    /// "forty minute" and "seventy-one" are the same words in and out,
    /// while "40 min" or "71/100" invite a "min" or a "slash" the voice
    /// would read aloud. That is a judgement, not a measurement — the
    /// phone run is where it gets one. The rationale is one sentence,
    /// which is the shape Aura's verdict would take (§168a).
    static let answer = "Today's session is a forty minute easy run. "
        + "Readiness is seventy-one out of a hundred: you slept well, "
        + "but yesterday's ride is still in your legs, so keep it easy."

    /// THE SENTENCE TO SAY, verbatim — on the Chat tab, in the Settings
    /// caption and at the top of the conversation log, so Ryad reads it
    /// off the phone rather than remembering it. Measured on the 0.6B
    /// weights (AC-222, §67): the model IGNORES a system instruction
    /// that says "always call the session tool" and calls it only when
    /// the QUESTION names the tool. So the demo asks the person to name
    /// it, and writes no instruction that pretends otherwise.
    static let sentenceToSay = "Use the session tool to find out what today's session is."

    /// The tool both minds are handed when Tools is on (F-2 = A: at
    /// construction, never through the coordinator).
    ///
    /// `call` runs INSIDE the reply, on whatever task the mind runs it
    /// (F-1 = B), so it hops to the recorder's actor and WAITS for the
    /// write before it answers. That await is what orders the evidence:
    /// the recorder holds the call before the model sees the answer, the
    /// model sees the answer before it says its last word, and the turn's
    /// row is written after that — so `record(_:)` on the model always
    /// finds this call already there.
    static func tool(recording recorder: SessionToolRecorder) -> ReplyTool {
        ReplyTool(name: name, description: description) { _ in
            await recorder.record(answer)
            return answer
        }
    }
}

/// WHAT THE TOOL ANSWERED, this turn — the demo's evidence (4w).
///
/// A phone run proves AC-222/AC-223 on device only if the log can say,
/// per turn, whether the session tool was CALLED and what it answered;
/// the reply's words alone cannot, because a model that never called
/// may still invent a session (§60 saw this mind invent a border). So
/// the tool writes here, and `TranscribeModel.record(_:)` drains this
/// into the turn's row. Main-actor, like every other piece of demo state
/// the screen reads (`MindAssetsState`, `ProbeState`).
///
/// One limit, named: the recorder does not know WHICH turn a call
/// belongs to. A call that lands after its turn was barged (AC-226) is
/// drained by the NEXT row — the row's `BARGED IN` mark beside a
/// tool-less line, and the next row's call, are how to read that.
@MainActor
@Observable
final class SessionToolRecorder {
    /// The answers recorded since the last drain — the calls of the turn
    /// in flight. Usually zero or one.
    private(set) var pending: [String] = []
    /// Every call since launch, for the Chat tab's one-line witness.
    private(set) var totalCalls = 0

    func record(_ answer: String) {
        pending.append(answer)
        totalCalls += 1
    }

    /// Hands over the turn's calls and forgets them: one row is the
    /// farthest a call may travel.
    func drain() -> [String] {
        defer { pending.removeAll() }
        return pending
    }
}
