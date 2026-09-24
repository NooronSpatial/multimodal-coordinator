// THE MIND'S SESSION SEAM (5b, SPEC §208/6; D-116 F-1 A, F-2 A).
//
// Before 5b the Apple mind built a NEW vendor session for every reply,
// so every turn prefilled the instructions, the tool schemas and the
// whole remembered past again — 3.3–3.9 s to the first token on the diet
// app's phone, first turn or twentieth (SPEC §207). A session that lives
// for the conversation prefills them once.
//
//     turn 1   make(instructions, tools, seed: [])   ─▶ respond("log 84 kilos")
//     turn 2                                            respond("and a coffee")
//     turn 3                                            respond("what did I eat?")
//              ↑ made ONCE                              ↑ only the new words, every turn
//
// Two protocols, in this library's vocabulary and never the vendor's, so
// a test — this library's or a caller's — can stand in for the model on a
// machine that has none. The Apple model reports `modelNotReady` on the
// machine this was written on; every row of §210 that is not a phone row
// drives a fake through here. `WeightsFetching` is the precedent (AC-249).
//
// WHO DECIDES WHEN A SESSION IS KEPT: not these protocols. They make a
// session and ask it; the keeper (`SessionKeeper`) decides, turn by
// turn, whether the session still holds what the memory holds (D-118
// F-12 C) and whether its last answer finished on its own (D-117 F-10 A).

/// What one answer of a session streams (5b): the answer so far, and —
/// the moment it happens — each tool the model used (D-117 F-8 A).
public enum MindSessionUpdate: Sendable, Equatable {
    /// The whole answer so far: CUMULATIVE, again and again (the Apple
    /// API's shape, SPEC §71).
    case snapshot(String)
    /// A tool ran during this answer — sent once it has run, before the
    /// words it answered go back to the model.
    case toolRan(ToolUse)
}

/// ONE SESSION WITH A MIND — what a conversation keeps between turns.
///
/// A session holds what it was born with (the instructions, the tools'
/// declarations, the seed) and everything it has answered since. It
/// grows only by answering: nothing outside it can add, edit or remove
/// what it holds — which is why a cut answer ends the session's use
/// rather than being repaired (D-117 F-10 A).
public protocol MindSession: Sendable {
    /// Answers `prompt`, which the session appends to what it holds, and
    /// streams the answer (`MindSessionUpdate`): CUMULATIVE snapshots —
    /// the whole answer so far, again and again (the Apple API's shape,
    /// SPEC §71) — and a `.toolRan` for every tool the model used.
    ///
    /// `tools` is the table whose BODIES this answer runs. Its
    /// declarations are the ones the session was made with — the keeper
    /// never hands a session a table that shows the model anything else
    /// (`ToolTable`'s `==`) — so nothing about the tools is sent to the
    /// model again. The bodies are read per answer so that a table
    /// rebuilt for each call runs THAT call's closures, and
    /// `options.confirmedTools` is THIS call's yes and no other's (4z,
    /// D-110 F-10 B-ii: a yes is bound to the call that carries it).
    func respond(to prompt: String, tools: ToolTable,
                 options: GenerationOptions) -> AsyncThrowingStream<MindSessionUpdate, any Error>
}

/// Makes sessions. The Apple mind's is `AppleSessionMaker`; a test's is a
/// fake that writes down what it was asked (SPEC §210's instrument).
public protocol MindSessionMaking: Sendable {
    /// Why no session can start here, or `nil`. Asked at every door and
    /// never cached: a download can complete between two turns.
    var unavailable: MindUnavailable? { get }

    /// A new session, born holding `instructions`, the declarations of
    /// `tools`, and `seed` — the past this session should know, oldest
    /// first (D-116 F-2 A: `ReplyContext.history` is the seed).
    func makeSession(instructions: String?, tools: ToolTable,
                     seed: [ConversationTurn]) throws -> any MindSession
}
