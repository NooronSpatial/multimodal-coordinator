// THE KEEPER — one session for one conversation (5b; D-116 F-1 A, F-2 A;
// D-117 F-10 A; D-118 F-12 C).
//
// RED SKELETON: the shape without the judgment. It makes a FRESH session
// for every reply — today's behaviour, expressed through the new seam —
// so the rows that ask for one session across many turns fail first.

/// Keeps one `MindSession` for the conversation a generator is, and
/// decides — turn by turn — whether the next answer continues it or a new
/// one is seeded from the memory.
///
/// It is the Apple generator's snapshot source: the run above it
/// (`AppleReplyRun`) is unchanged, and still sees one stream of
/// cumulative snapshots per reply.
final class SessionKeeper: ReplySnapshotStreaming, Sendable {
    let maker: any MindSessionMaking
    /// The generator's own table — the one a call runs with when its
    /// options carry none (4z, D-110 F-2 = A).
    let tools: ToolTable

    init(maker: any MindSessionMaking, tools: ToolTable) {
        self.maker = maker
        self.tools = tools
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
                   instructions: String?) -> AsyncThrowingStream<String, any Error> {
        let tools = resolvedTools(for: context.options)
        // The session is made INSIDE the stream's task, never in
        // `openReply`: the coordinator awaits `openReply` inline on its one
        // serial loop, and a model warm-up in that window is 4e's blocker 3
        // one seam over — the first turn freezing the whole conversation
        // (AC-115, measured: 1839 ms cold vs ~280 ms warm).
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try self.maker.makeSession(
                        instructions: instructions, tools: tools, seed: context.history)
                    for try await snapshot in session.respond(to: context.transcript, tools: tools,
                                                              options: context.options) {
                        continuation.yield(snapshot)
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
}
