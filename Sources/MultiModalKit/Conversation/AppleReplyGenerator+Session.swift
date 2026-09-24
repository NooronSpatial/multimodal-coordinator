// THE APPLE MIND'S SESSION (5b, SPEC §208/6; D-116 F-1 A).
//
// The vendor side of `MindSession`: one `LanguageModelSession`, made once
// for a conversation and asked again every turn. Until 5b this file's
// transcript-building lived in `FoundationModelSnapshots.session(...)`
// and ran on EVERY reply (D-057 F-2 = A, reversed in the open by D-116);
// it now runs when a session is BORN — the first turn, and every re-seed.
//
// Nothing here decides whether a session is kept. `SessionKeeper` does
// that; this file only knows how to make one and how to ask it.

import FoundationModels
import Synchronization

// MARK: - the maker

/// Makes Apple sessions — the default `MindSessionMaking` of
/// `AppleReplyGenerator`. Public for the reason `HubWeightsFetcher` is:
/// it is the real conformer a caller's fake stands beside.
@available(macOS 26.0, iOS 26.0, *)
public struct AppleSessionMaker: MindSessionMaking {
    public init() {}

    /// The vendor's verdict, in the contract's words — read fresh every
    /// time (`AppleMind.readiness()`).
    public var unavailable: MindUnavailable? { AppleMind.readiness() }

    public func makeSession(instructions: String?, tools: ToolTable,
                            seed: [ConversationTurn]) throws -> any MindSession {
        try AppleSession(instructions: instructions, tools: tools, seed: seed)
    }
}

// MARK: - one session

/// One `LanguageModelSession`, kept for a conversation.
///
/// `Sendable` without a lock of its own: both stored values are — the
/// vendor declares `LanguageModelSession` `@unchecked Sendable`, and the
/// route is a `Mutex`. One answer at a time is the KEEPER's rule (a busy
/// session is never asked again, D-117 F-10 A), which is also what keeps
/// the vendor's `concurrentRequests` from being reachable through here.
@available(macOS 26.0, iOS 26.0, *)
final class AppleSession: MindSession {
    let session: LanguageModelSession
    /// Where this answer's tool bodies and yes are read (see `ToolRoute`).
    let route: ToolRoute

    init(instructions: String?, tools: ToolTable, seed: [ConversationTurn]) throws {
        let route = ToolRoute(tools)
        self.route = route
        // One call for both shapes: `.empty` maps to `[]`, which is the
        // vendor's default and the pre-4w session (see `entries`).
        self.session = LanguageModelSession(
            tools: try tools.tools.map { try AppleToolAdapter($0, route: route) },
            transcript: Transcript(entries: Self.entries(instructions: instructions, seed: seed)))
    }

    /// What a session is BORN holding, built from a transcript WE
    /// assembled (4r, F-1 = B).
    ///
    /// Apple's native shape for "what was said before" is
    /// `Transcript.Entry`, so the past is mapped onto it rather than
    /// flattened into the prompt — a flattened past is a past the model
    /// has to parse.
    ///
    /// The current thought is deliberately NOT an entry here —
    /// `respond(to:)` supplies it — or the model would be shown the
    /// question twice.
    ///
    /// `toolDefinitions: []` on the instructions entry, ALWAYS: the
    /// vendor fills that list itself from the tools it was handed
    /// (measured 2026-09-11: `tools: [session]` with `[]` written here
    /// yields an instructions entry whose `toolDefinitions` is
    /// `["session"]`), so a definition written here would only repeat
    /// what it already knows. Also measured: writing one anyway does NOT
    /// double it. A mind with NO tools hands the vendor `[]` — its own
    /// default — and that session's transcript was measured
    /// byte-identical to the pre-4w `init(transcript:)` one (AC-227's
    /// Mac half).
    ///
    /// Each remembered turn is a `.prompt`, then — when it used tools —
    /// the TYPED calls and their outputs (5b, D-116 F-3 A, AC-305), then a
    /// `.response` with the mind's words and "…" marking a reply the
    /// person cut off. A turn with no tool replays exactly as it did
    /// before 5b. A turn where a tool ran and the mind said nothing keeps
    /// its act (D-119) and an empty response — the vendor's own shape
    /// when the model says nothing after a tool.
    static func entries(instructions: String?, seed: [ConversationTurn]) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        if let instructions {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: [])))
        }
        for (index, turn) in seed.enumerated() {
            entries.append(.prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: turn.said))])))
            entries.append(contentsOf: toolEntries(turn.tools, turn: index))
            entries.append(.response(Transcript.Response(
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(
                    content: turn.replied + (turn.interrupted ? "…" : "")))])))
        }
        return entries
    }

    /// A turn's tools as the vendor writes them when the model uses some:
    /// ONE tool-calls entry holding every call, then one output per call,
    /// the output carrying its call's id. The call shows the model its own
    /// arguments; the output is exactly what the model was told
    /// (`wordsForModel`) — a refusal included. Nothing for a turn with no
    /// tool.
    static func toolEntries(_ uses: [ToolUse], turn: Int) -> [Transcript.Entry] {
        guard !uses.isEmpty else { return [] }
        let ids = uses.indices.map { "turn-\(turn)-tool-\($0)" }
        let calls = zip(ids, uses).map { id, use in
            Transcript.ToolCall(id: id, toolName: use.name,
                                arguments: GeneratedContent(replaying: use.arguments))
        }
        var entries: [Transcript.Entry] = [.toolCalls(Transcript.ToolCalls(id: "turn-\(turn)-tools", calls))]
        for (id, use) in zip(ids, uses) {
            entries.append(.toolOutput(Transcript.ToolOutput(
                id: id, toolName: use.name,
                segments: [.text(Transcript.TextSegment(content: use.outcome.wordsForModel))])))
        }
        return entries
    }

    func respond(to prompt: String, tools: ToolTable,
                 options: GenerationOptions) -> AsyncThrowingStream<MindSessionUpdate, any Error> {
        let vendor = Self.vendorOptions(for: options)
        return AsyncThrowingStream { continuation in
            // Set BEFORE the vendor can call a tool — this builder runs
            // before `respond` returns. The adapters were made at the
            // session's birth, and must run THIS call's bodies with THIS
            // call's yes (4z F-10 B-ii), and report each use into THIS
            // answer's stream (D-117 F-8 A).
            self.route.set(tools, confirmed: options.confirmedTools) { use in
                continuation.yield(.toolRan(use))
            }
            let task = Task {
                do {
                    for try await snapshot in self.session.streamResponse(to: prompt, options: vendor) {
                        continuation.yield(.snapshot(snapshot.content))
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The caller's levers, in the vendor's words (AC-233, AC-234). Pure
    /// and static so a test can read what a given `GenerationOptions`
    /// becomes without a model in the room. (Moved here unchanged from
    /// `FoundationModelSnapshots`, which 5b retired.)
    ///
    /// - the budget is ALWAYS set: `maxTokens ?? 1024` (F-6 = A — the
    ///   cap is a ceiling, not a target).
    /// - temperature `0` asks for `.greedy` — the vendor's own name for
    ///   "no randomness". Greedy has no randomness to seed, so it wins
    ///   over a seed given beside it.
    /// - a seed asks for `.random(top: 50, seed:)` — TOP-K sampling: the
    ///   model picks among its 50 likeliest next tokens. Fifty is a
    ///   conventional width, not a tuned one; the SEED is what AC-234
    ///   needs.
    /// - `temperature` is passed when given, widened `Float → Double`.
    ///   `nil` everything else leaves the vendor's defaults untouched.
    static func vendorOptions(for options: GenerationOptions) -> FoundationModels.GenerationOptions {
        var sampling: FoundationModels.GenerationOptions.SamplingMode?
        if options.temperature == 0 {
            sampling = .greedy
        } else if let seed = options.seed {
            sampling = .random(top: Self.seededTopK, seed: seed)
        }
        return FoundationModels.GenerationOptions(
            sampling: sampling,
            temperature: options.temperature.map(Double.init),
            maximumResponseTokens: options.maxTokens ?? AppleReplyGenerator.defaultTokenBudget)
    }

    /// The `top` of `.random(top:seed:)` when a seed is given — see
    /// `vendorOptions`: a conventional value, not a measured one.
    static let seededTopK = 50
}

// MARK: - this answer's tools

/// THIS ANSWER'S TOOLS, for a session that outlives one answer (5b).
///
/// The vendor keeps the adapters it was handed when the session was
/// born, and runs them from inside `streamResponse`, where no argument of
/// ours can reach. When a session lived for one reply, what an adapter
/// captured at birth WAS that reply's. Kept for a conversation, it would
/// run turn one's closures and honour turn one's yes on turn five — and a
/// yes is bound to the call that carries it (4z, D-110 F-10 B-ii). So the
/// adapters hold the DECLARATION (what the model is shown) and read the
/// body and the yes here, from the answer in progress.
///
/// One slot is enough: a session answers one prompt at a time (the
/// keeper's rule). The `Mutex` is there because the vendor calls an
/// adapter on its own thread.
final class ToolRoute: Sendable {
    struct Now: Sendable {
        let table: ToolTable
        let confirmed: Set<String>
        /// Where this answer hears that a tool ran (5b, D-117 F-8 A).
        let report: @Sendable (ToolUse) -> Void
    }

    private let slot: Mutex<Now>

    init(_ table: ToolTable, confirmed: Set<String> = [],
         report: @escaping @Sendable (ToolUse) -> Void = { _ in }) {
        slot = Mutex(Now(table: table, confirmed: confirmed, report: report))
    }

    /// The answer about to start: its table (whose bodies run), its yes,
    /// and where it hears of each use.
    func set(_ table: ToolTable, confirmed: Set<String>,
             report: @escaping @Sendable (ToolUse) -> Void = { _ in }) {
        slot.withLock { $0 = Now(table: table, confirmed: confirmed, report: report) }
    }

    var now: Now { slot.withLock { $0 } }
}
