// THE KEEPER — one session for one conversation (5b; D-116 F-1 A, F-2 A;
// D-117 F-10 A; D-118 F-12 C).
//
//     a call arrives ──▶ which session answers it?
//
//       another identity (instructions, tool declarations)?
//           └─ yes ─▶ a session ASIDE, made for this call; the
//                     conversation's is not touched          (AC-309)
//       the kept session's last answer finished on its own,
//       AND it holds exactly the history this call brings?
//           └─ yes ─▶ CONTINUE it: the model is sent the new words only
//                                                             (AC-303)
//       otherwise ─▶ SEED a new one from the history (F-2 A), and it
//                    becomes the conversation's               (F-4 A)
//
// Piece 1 of 5b. The window rule of D-118 F-12 C (a kept session may hold
// MORE than the memory's window), the vendor's context wall, the health
// report and `endConversation` are later pieces; until then "holds exactly
// the history" is equality, and every one of those cases re-seeds — which
// is today's cost, never a wrong answer.

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
final class SessionKeeper: ReplySnapshotStreaming, Sendable {
    let maker: any MindSessionMaking
    /// The generator's own table — the one a call runs with when its
    /// options carry none (4z, D-110 F-2 = A).
    let tools: ToolTable
    private let state = Mutex(State())

    init(maker: any MindSessionMaking, tools: ToolTable) {
        self.maker = maker
        self.tools = tools
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
        /// barge, a deadline, a failure — never lowers it, so the session
        /// is never asked again: a live session only grows by answering,
        /// and what the vendor keeps of a cut answer is unknown. It is
        /// also what keeps a second answer from ever starting on a session
        /// still busy with the first (the vendor's `concurrentRequests`).
        var busy: Bool
    }

    private struct State: Sendable {
        var kept: Kept?
        /// The last ticket handed out.
        var issued = 0
    }

    /// Which session answers one call, and whether it is the
    /// conversation's (`ticket`) or made aside for this call (`nil`).
    private struct Lease {
        let session: any MindSession
        let ticket: Int?
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
                do {
                    let lease = try self.lease(for: identity, history: context.history)
                    var answer = ""
                    for try await update in lease.session.respond(to: context.transcript,
                                                                  tools: identity.tools,
                                                                  options: context.options) {
                        if case .snapshot(let snapshot) = update { answer = snapshot }
                        continuation.yield(update)
                        try Task.checkCancellation()
                    }
                    // Checked once more AFTER the stream: an answer the
                    // vendor finished but its listener abandoned (a barge
                    // landing on the last word) did not finish for THIS
                    // conversation, and must not make the session answerable.
                    //
                    // THE BELT, NOT THE GUARD — measured, not assumed
                    // (mutation M4, docs/evidence/5b): with this line gone
                    // every row stays green, because equality already
                    // refuses that session. The memory writes such a turn
                    // as INTERRUPTED, or refuses it when no word got
                    // through, so the next history never equals what the
                    // session holds. Kept because it costs one check and
                    // makes the rule hold without leaning on how the
                    // memory writes a cut turn — the 4b precedent: record
                    // the redundancy, never pretend each line is
                    // load-bearing alone.
                    try Task.checkCancellation()
                    self.finished(lease, turn: ConversationTurn(said: context.transcript, replied: answer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
            case keep(any MindSession, ticket: Int)
            case seed(ticket: Int)
        }
        let decision: Decision = state.withLock { state in
            if var kept = state.kept {
                // AC-309: a call that shows the model other instructions
                // or other tools is answered aside; the conversation's own
                // session — whatever state it is in — is not touched.
                guard kept.identity == identity else { return .aside }
                if !kept.busy, kept.holds == history {
                    kept.busy = true
                    state.kept = kept
                    return .keep(kept.session, ticket: kept.ticket)
                }
            }
            state.issued += 1
            state.kept = nil
            return .seed(ticket: state.issued)
        }

        switch decision {
        case .keep(let session, let ticket):
            return Lease(session: session, ticket: ticket)
        case .aside:
            let session = try maker.makeSession(instructions: identity.instructions,
                                                tools: identity.tools, seed: history)
            return Lease(session: session, ticket: nil)
        case .seed(let ticket):
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
            return Lease(session: session, ticket: installed ? ticket : nil)
        }
    }

    /// The answer FINISHED ON ITS OWN — the only way a session becomes
    /// answerable again (D-117 F-10 A). It now holds this turn too,
    /// written the way the memory writes it (`ConversationTurn.remembered`),
    /// so the next call's history can be compared with it exactly.
    private func finished(_ lease: Lease, turn: ConversationTurn) {
        // Made aside for one call: the conversation never held it.
        guard let ticket = lease.ticket else { return }
        // Half a turn — an empty answer. The memory will not keep it and
        // the session did, so the two can never agree again: the session
        // stays busy, and the next call seeds a new one.
        guard let remembered = turn.remembered else { return }
        state.withLock { state in
            guard var kept = state.kept, kept.ticket == ticket else { return }
            kept.holds.append(remembered)
            kept.busy = false
            state.kept = kept
        }
    }
}
