/// `TurnCoordinator` — THINK IN THE GATE (5d piece 4; SPEC §250–§255, D-144).
///
///     the final ─▶ openEarly: the mind opens AT ONCE; `held` starts
///                    │ everything the reply sends is appended to `held` (handleReply)
///                    ├─ the gate runs out  ─▶ releaseHeld: thinking, then `held`, replayed in order
///                    └─ the person goes on ─▶ throwAwayEarlyReply: the reply ticket raised, cancelled
///
/// Nothing is said before the gate runs out, and a person who goes on still
/// kills the reply in silence (AC-81); only the THINKING moves earlier. Off
/// unless the app asks (`Config.thinksInTheGate`, F-45 A), and never for a
/// mind that may act (F-47 A).

extension TurnCoordinator {

    /// The final was accepted and the gate armed: open the reply now, held —
    /// when the app asked for it (F-45 A), and never for a mind that may act
    /// (F-47 A): its act could not be held.
    func openEarlyIfAsked(
        turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        guard config.thinksInTheGate, !replyGenerator.mayActDuringReply else { return }
        current?.held = []
        current?.earlyOpenedAt = clock?.now
        await openGeneration(of: ledger.text, turn: turn, early: true,
                             forwardingInto: &group, via: input)
    }

    /// The gate ran out with an early reply held (the turn already moved to
    /// `thinking`): ③ ends HERE, and what was held goes on as if it had just
    /// arrived — so a token already held makes ④ zero.
    func releaseHeld(
        turn: Int,
        forwardingInto group: inout TaskGroup<Void>,
        via input: AsyncStream<Input>.Continuation
    ) async {
        guard let live = current, live.turn == turn, let held = live.held else { return }
        let now = clock?.now
        current?.held = nil
        current?.openedAt = now
        if let opened = live.earlyOpenedAt, let now {
            let thought = opened.duration(to: now)
            current?.thoughtInTheGate = thought
            latencyReporter?.earlyReply(EarlyReply(turn: turn, kept: true, thought: thought))
        }
        if let failure = live.heldOpenFailure {
            current?.heldOpenFailure = nil
            failTurn(turn, with: failure)
            return
        }
        for update in held {
            // A held failure or terminal may end the turn part-way through.
            guard let still = current, still.turn == turn else { return }
            await handleReply(update, turn: turn, reply: still.reply,
                              forwardingInto: &group, via: input)
        }
    }

    /// Whether a reply's update goes on NOW, for a live turn: the REPLY
    /// TICKET stops a reply thrown away in the gate (it left the turn alive,
    /// so the turn ticket cannot), and while the gate still runs the update
    /// is HELD — not a word, not a terminal, not a failure leaves the
    /// coordinator. `releaseHeld` replays what was held.
    func goesOnNow(_ update: ReplyUpdate, reply: Int) -> Bool {
        guard let live = current else { return false }
        guard live.reply == reply else {
            staleRepliesDropped += 1
            return false
        }
        guard live.held == nil else {
            current?.held?.append(update)
            return false
        }
        return true
    }

    /// The person went on during the gate: the early reply is thrown away in
    /// silence (AC-365). The reply ticket is raised in THIS step, before any
    /// await, so nothing the reply sends afterwards gets past `handleReply`;
    /// the cancel is the optimization, after the guarantee. The mind counts
    /// it as a cut answer (F-44 A).
    func throwAwayEarlyReply() async {
        guard let live = current, live.held != nil else { return }
        replyTickets += 1
        current?.reply = replyTickets
        current?.held = nil
        current?.heldOpenFailure = nil
        current?.earlyOpenedAt = nil
        current?.replyRun = nil
        if let opened = live.earlyOpenedAt, let now = clock?.now {
            latencyReporter?.earlyReply(EarlyReply(turn: live.turn, kept: false,
                                                   thought: opened.duration(to: now)))
        }
        await live.replyRun?.cancel()
    }
}
