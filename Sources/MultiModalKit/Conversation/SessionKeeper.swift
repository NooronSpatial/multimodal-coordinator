// THE KEEPER — one session for one conversation (5b; D-116 F-1 A, F-2 A;
// D-117 F-10 A; D-118 F-12 C).
//
//     a call arrives ──▶ which session answers it?
//
//       another identity (instructions, tool declarations)?
//           └─ yes ─▶ a session ASIDE, made for this call; the
//                     conversation's is not touched          (AC-309)
//       the kept session's last answer finished on its own,
//       AND the history this call brings is its NEWEST turns?
//           └─ yes ─▶ CONTINUE it: the model is sent the new words only
//                     (AC-303) — however many older turns it still
//                     holds that the memory's bound dropped (F-12 C)
//       otherwise ─▶ SEED a new one from the history (F-2 A), and it
//                    becomes the conversation's               (F-4 A)
//
// And when the conversation's session ENDS (piece 3a): an answer that
// did not finish on its own lets it go at once, `endConversation()` lets
// it go and moves the ticket on, and every birth of the conversation's
// session is reported with its reason (`SessionSeedReason`, D-118 F-13 A).
//
// And ONCE, an answer is asked again (piece R, SPEC §213; D-122):
//
//     ask 1 ── a tool RAN ── the vendor fails with no name, no word yet
//        └─▶ ask 2: a FRESH session from the same history, the same words
//            (F-18 A); a repeat of a call already made is answered from
//            its RECORD (F-16 A) — so the person hears one answer and no
//            write runs twice. Never a third ask (F-15 A); never after a
//            word (F-19 A); never for a failure with a name.
//
// And at the vendor's WALL (piece 3b, AC-308; D-118 F-12 C, D-124 F-22 B):
// a session kept past the memory's window grows until its context is
// full. Full before any word, in a session that held MORE than the window:
// it is let go, and the turn is asked again once in a session born from
// the window alone — the same one ask as the retry, repeats answered from
// their records. Full after a word, or in a session that held just the
// window: the turn fails as AC-116 does, and the next turn is re-seeded.

import Synchronization

/// Keeps one `MindSession` for the conversation a generator is, and
/// decides — call by call — whether the answer continues it, is seeded
/// anew, or is made aside.
///
/// It is the Apple generator's snapshot source: the run above it
/// (`AppleReplyRun`) is unchanged and still sees one stream of cumulative
/// snapshots per reply. `Sendable` through one `Mutex`: every decision is
/// one lock step, nothing suspends under the lock, and a session is MADE
/// outside it (a vendor's session may be slow to make, and nothing else
/// should wait behind that).
///
/// Gated on the Apple mind's OS since piece R: whether to ask again is
/// read from the Apple failure table (`AppleEnding`) — the same one the
/// run reports from — and the keeper is the Apple mind's (F-17 A).
@available(macOS 26.0, iOS 26.0, *)
final class SessionKeeper: ReplySnapshotStreaming, Sendable {
    let maker: any MindSessionMaking
    /// The generator's own table — the one a call runs with when its
    /// options carry none (4z, D-110 F-2 = A).
    let tools: ToolTable
    /// Where each session's birth is reported, with its reason (D-118
    /// F-13 A); `nil` reports nothing.
    let diagnostics: PipelineDiagnostics?
    private let state = Mutex(State())

    init(maker: any MindSessionMaking, tools: ToolTable, diagnostics: PipelineDiagnostics? = nil) {
        self.maker = maker
        self.tools = tools
        self.diagnostics = diagnostics
    }

    /// Whether the conversation holds a session right now — for the rows
    /// that prove one was released (AC-307, AC-310).
    var holdsSession: Bool { state.withLock { $0.kept != nil } }

    /// The conversation is over (D-117 F-9 A): its session is let go, and
    /// the ticket moves on in the SAME lock step, so an answer still
    /// running for the old conversation can change nothing when it ends.
    /// The next turn is a new conversation's first.
    func endConversation() {
        state.withLock { state in
            state.issued += 1
            state.kept = nil
            state.ending = nil
        }
    }

    /// What a session shows the model and cannot change once born: its
    /// instructions and its tools' declarations (`ToolTable`'s `==`
    /// compares declarations, never bodies). A call is answered by a
    /// session only when the two are equal.
    struct Identity: Equatable, Sendable {
        let instructions: String?
        let tools: ToolTable
    }

    /// The conversation's session and what the keeper knows about it.
    private struct Kept: Sendable {
        let session: any MindSession
        let identity: Identity
        /// Which birth this is — a monotonic ticket (§4.1). An answer
        /// that ends after the conversation moved on finds another ticket
        /// here, and changes nothing.
        let ticket: Int
        /// What the session holds, as the MEMORY writes it, oldest first:
        /// the seed it was born with, then every answer it finished.
        var holds: [ConversationTurn]
        /// True from the moment an answer starts until it FINISHES ON ITS
        /// OWN (D-117 F-10 A). An answer that ends any other way — a
        /// barge, a deadline, a failure — never lowers it: the session is
        /// let go instead (`ended`), because a live session only grows by
        /// answering and what the vendor keeps of a cut answer is unknown.
        /// A cut reaches the keeper when its task sees the cancel, which
        /// may be after the next call has come — `busy` is what that call
        /// finds, and it seeds anew. It is also what keeps a second answer
        /// from ever starting on a session still busy with the first (the
        /// vendor's `concurrentRequests`).
        var busy: Bool
    }

    private struct State: Sendable {
        var kept: Kept?
        /// The last ticket handed out.
        var issued = 0
        /// Why the conversation's last session was let go, for the next
        /// birth to report (D-118 F-13 A). `nil` after `endConversation()`
        /// and before the first turn: the next birth is a new conversation.
        var ending: SessionSeedReason?
    }

    /// Which session answers one call, and whether it is the
    /// conversation's (`ticket`) or made aside for this call (`nil`).
    private struct Lease {
        let session: any MindSession
        let ticket: Int?
        /// The session holds MORE turns than this call's history — a kept
        /// session continued past the memory's window (F-12 C). Only then
        /// can a re-seed from the window be smaller, so only then is the
        /// wall worth one more ask (D-124 F-22 B).
        var outgrew = false
    }

    var unavailable: MindUnavailable? { maker.unavailable }

    /// The table THIS call runs with (AC-275, F-2 = A): the call's when its
    /// options carry one — `.empty` meaning no tool this turn — and the
    /// generator's own otherwise. The same rule the scripted mind and the
    /// MLX run apply.
    func resolvedTools(for options: GenerationOptions) -> ToolTable {
        options.tools ?? tools
    }

    func snapshots(for context: ReplyContext,
                   instructions: String?) -> AsyncThrowingStream<MindSessionUpdate, any Error> {
        let identity = Identity(instructions: instructions, tools: resolvedTools(for: context.options))
        // The session is chosen and made INSIDE the stream's task, never
        // in `openReply`: the coordinator awaits `openReply` inline on its
        // one serial loop, and a model warm-up in that window is 4e's
        // blocker 3 one seam over — the first turn freezing the whole
        // conversation (AC-115, measured: 1839 ms cold vs ~280 ms warm).
        return AsyncThrowingStream { continuation in
            let task = Task {
                // The session answering NOW — the first ask's, or the
                // retry's: the one `ended` lets go of if anything throws.
                var lease: Lease?
                do {
                    var current = try self.lease(for: identity, history: context.history)
                    lease = current
                    var answer = Answer()
                    do {
                        try await self.ask(current, context, tools: identity.tools, into: &answer, continuation)
                    } catch {
                        // The ONE re-ask — §213's retry or the wall's — or
                        // the error as it was.
                        guard let reask = self.reask(after: error, answer, in: current) else { throw error }
                        self.ended(current, by: error)
                        lease = nil
                        if case .unexplained(let words) = reask {
                            self.diagnostics?.noteMindReplyRetried(after: words)
                        }
                        // F-18 A: a fresh session from the SAME history,
                        // the same words — for the wall, the memory's
                        // window, which is what makes it smaller. F-16 A:
                        // the tools stay in the schema, and every call the
                        // first ask RAN is a record a repeat is answered
                        // from.
                        current = try self.lease(for: identity, history: context.history)
                        lease = current
                        answer = Answer(records: answer.used)
                        try await self.ask(current, context, tools: identity.tools.replaying(answer.records),
                                           into: &answer, continuation)
                    }
                    // Checked once more AFTER the stream: an answer the
                    // vendor finished but its listener abandoned (a barge
                    // landing on the last word) did not finish for THIS
                    // conversation, and must not make the session answerable.
                    //
                    // THE BELT, NOT THE GUARD — measured, not assumed
                    // (mutation M4, docs/evidence/5b): with this line gone
                    // every row stays green, because the rule already
                    // refuses that session. The memory writes such a turn
                    // as INTERRUPTED, or refuses it when no word got
                    // through, so the next history's newest turn is never
                    // the one the session holds last (equality in 3a, the
                    // window rule since 3b). Kept because it costs one check and
                    // makes the rule hold without leaning on how the
                    // memory writes a cut turn — the 4b precedent: record
                    // the redundancy, never pretend each line is
                    // load-bearing alone.
                    try Task.checkCancellation()
                    // What the answering session HOLDS: after a retry, its
                    // repeats too — so the next turn continues it only if
                    // it repeated every call the memory remembers.
                    self.finished(current, turn: ConversationTurn(said: context.transcript,
                                                                  replied: answer.words, tools: answer.held))
                    continuation.finish()
                } catch {
                    // Let go BEFORE the stream says so: the run, the
                    // coordinator and a text caller all hear of a failure
                    // after this line, so nothing kept outlives it (AC-307).
                    self.ended(lease, by: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - one ask

    /// One answer as it streams, as the keeper must know it.
    private struct Answer {
        /// The words so far — the last snapshot.
        var words = ""
        /// The tools that RAN in this ask, passed on to the run as they ran.
        var used: [ToolUse] = []
        /// Every call the session holds from this ask, in order — a repeat
        /// answered from its record included (§213's retry).
        var held: [ToolUse] = []
        /// The calls a repeat is answered from: the first ask's, on the
        /// retry; none otherwise.
        var records: [ToolUse] = []
    }

    /// Asks `lease`'s session the call's words and streams its answer on.
    /// A tool use that repeats a record was answered from it — the run
    /// heard of that act when it RAN, in the first ask — so it is held, and
    /// not passed on twice.
    private func ask(_ lease: Lease, _ context: ReplyContext, tools: ToolTable, into answer: inout Answer,
                     _ continuation: AsyncThrowingStream<MindSessionUpdate, any Error>.Continuation) async throws {
        for try await update in lease.session.respond(to: context.transcript, tools: tools,
                                                      options: context.options) {
            switch update {
            case .snapshot(let snapshot):
                answer.words = snapshot
                continuation.yield(update)
            case .toolRan(let use):
                answer.held.append(use)
                if !answer.records.contains(where: { $0.answers(use.name, use.arguments) }) {
                    answer.used.append(use)
                    continuation.yield(update)
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Why an answer is asked again — at most once in a turn.
    private enum Reask {
        /// §213 R-1: no reason the library can name, after a tool ran.
        case unexplained(String)
        /// AC-308: the vendor's context is full, in a session that outgrew
        /// the memory's window.
        case wall
    }

    /// Whether the FIRST ask's failure is asked again — or `nil`, and the
    /// error ends the answer as it always did. Read only where the first
    /// ask throws, so never a third ask (F-15 A). Two cases, both before
    /// any word and neither on a cut answer:
    ///
    /// - §213 R-1: the vendor failed with no reason this library can name
    ///   (R-2) after at least one tool RAN. Never for a failure with a name.
    /// - AC-308 at the wall: the context is full, and the session held more
    ///   than the memory's window (`outgrew`), so a re-seed from the window
    ///   is smaller. A session that held just the window would meet the
    ///   same wall with the same past (D-124 F-22 B).
    ///
    /// "Before any word" is no snapshot with anything in it — whitespace
    /// included: what the run has emitted is the text it compares every
    /// later snapshot against, and a re-ask starts that text from nothing.
    ///
    /// `!Task.isCancelled` IS A BELT, NOT A GUARD — measured (mutation M19,
    /// docs/evidence/5b): with it gone every row stays green, because a
    /// cut reaches this keeper as a `CancellationError`, which the table
    /// reads as `.cut` before anything else, or as a stream that simply
    /// ends. It stays for the vendor this Mac cannot run: if the real
    /// session raises an error of its OWN when its answer is cut, that
    /// error has no name — and without this line a barged turn whose tool
    /// had run would be asked again.
    private func reask(after error: any Error, _ answer: Answer, in lease: Lease) -> Reask? {
        guard !Task.isCancelled, answer.words.isEmpty else { return nil }
        switch AppleEnding(error) {
        case .failed(.unexplained(let words)) where !answer.used.isEmpty: return .unexplained(words)
        case .failed(.contextWindowExceeded) where lease.outgrew: return .wall
        default: return nil
        }
    }

    // MARK: - the rule

    /// Which session answers this call — the diagram at the top of this
    /// file, as code. The decision is ONE lock step; making a session is
    /// not, so a new one is installed only if no other call or ending
    /// moved the ticket on while it was being made (the reentrancy law).
    private func lease(for identity: Identity, history: [ConversationTurn]) throws -> Lease {
        enum Decision {
            case aside
            case keep(any MindSession, ticket: Int, outgrew: Bool)
            case seed(ticket: Int, because: SessionSeedReason)
        }
        let decision: Decision = state.withLock { state in
            let reason: SessionSeedReason
            if var kept = state.kept {
                // AC-309: a call that shows the model other instructions
                // or other tools is answered aside; the conversation's own
                // session — whatever state it is in — is not touched.
                guard kept.identity == identity else { return .aside }
                if !kept.busy, Self.continues(kept.holds, with: history) {
                    kept.busy = true
                    state.kept = kept
                    return .keep(kept.session, ticket: kept.ticket, outgrew: kept.holds.count > history.count)
                }
                reason = kept.busy ? .lastAnswerUnfinished : .memoryChanged
            } else {
                reason = state.ending ?? .newConversation
            }
            state.ending = nil
            state.issued += 1
            state.kept = nil
            return .seed(ticket: state.issued, because: reason)
        }

        switch decision {
        case .keep(let session, let ticket, let outgrew):
            return Lease(session: session, ticket: ticket, outgrew: outgrew)
        case .aside:
            let session = try maker.makeSession(instructions: identity.instructions,
                                                tools: identity.tools, seed: history)
            return Lease(session: session, ticket: nil)
        case .seed(let ticket, let reason):
            let session = try maker.makeSession(instructions: identity.instructions,
                                                tools: identity.tools, seed: history)
            let installed = state.withLock { state -> Bool in
                // Another call or ending took a newer ticket while this
                // session was being made: it answers this call, and the
                // conversation's session is the newer one.
                guard state.issued == ticket else { return false }
                state.kept = Kept(session: session, identity: identity, ticket: ticket,
                                  holds: history, busy: true)
                return true
            }
            // Reported outside the lock, and only for the conversation's
            // own session: an aside, or a seeding that lost the race to a
            // newer one, is not this conversation's (D-118 F-13 A).
            if installed { diagnostics?.noteMindSessionSeeded(reason, turns: history.count) }
            return Lease(session: session, ticket: installed ? ticket : nil)
        }
    }

    /// THE WINDOW RULE (D-118 F-12 C): a kept session is continued while
    /// the history a call brings — the memory's window — is its NEWEST
    /// turns, however many older ones it still holds. The memory's bound
    /// then decides only what a RE-SEED carries, and a conversation longer
    /// than the bound keeps one session until the vendor's wall.
    ///
    /// An empty window continues only a session that holds nothing: a
    /// memory switched off (`maxMemoryTurns` 0) keeps no past, and a
    /// session holding one would show the model a past the app chose not
    /// to keep — so with memory off, every turn is re-seeded with none.
    static func continues(_ holds: [ConversationTurn], with window: [ConversationTurn]) -> Bool {
        guard !window.isEmpty else { return holds.isEmpty }
        return holds.count >= window.count && holds.suffix(window.count).elementsEqual(window)
    }

    /// The answer FINISHED ON ITS OWN — the only way a session becomes
    /// answerable again (D-117 F-10 A). It now holds this turn too — its
    /// words AND its tools — written the way the memory writes it
    /// (`ConversationTurn.remembered`), so the next call's history can be
    /// compared with it exactly.
    private func finished(_ lease: Lease, turn: ConversationTurn) {
        // Made aside for one call: the conversation never held it.
        guard let ticket = lease.ticket else { return }
        // Half a turn — no words and no tool (D-119 keeps an act). The
        // memory will not keep it and the session did, so the two can
        // never agree again: let it go now, and say why.
        guard let remembered = turn.remembered else {
            release(ticket, because: .memoryChanged)
            return
        }
        state.withLock { state in
            guard var kept = state.kept, kept.ticket == ticket else { return }
            kept.holds.append(remembered)
            kept.busy = false
            state.kept = kept
        }
    }

    /// The answer did NOT finish on its own: the session is let go at once
    /// (AC-307), and the next birth will say why. A cancelled task is a
    /// cut — a barge, a deadline, a listener gone — whatever error the
    /// vendor raised on the way out; the vendor's full context is the wall
    /// (AC-308); anything else is a failure, in its own words.
    private func ended(_ lease: Lease?, by error: any Error) {
        guard let ticket = lease?.ticket else { return }
        let reason: SessionSeedReason
        if Task.isCancelled || error is CancellationError {
            reason = .lastAnswerUnfinished
        } else if AppleEnding(error) == .failed(.contextWindowExceeded) {
            reason = .contextFull   // AC-308: the next birth says it was the wall
        } else {
            reason = .lastAnswerFailed(String(describing: error))
        }
        release(ticket, because: reason)
    }

    /// Lets go of the conversation's session if it is still the one this
    /// ticket leased — an older ending changes nothing (the ticket law).
    private func release(_ ticket: Int, because reason: SessionSeedReason) {
        state.withLock { state in
            guard state.kept?.ticket == ticket else { return }
            state.kept = nil
            state.ending = reason
        }
    }
}
