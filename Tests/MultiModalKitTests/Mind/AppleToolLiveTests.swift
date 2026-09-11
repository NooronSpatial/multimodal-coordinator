import Foundation
import Testing
@testable import MultiModalKit
import MultiModalKitTesting

/// AC-223 THROUGH THE REAL MODEL (4w piece 3, D-101 F-1 = B, F-3 = C):
/// the Apple mind is handed ONE tool — a no-argument read of today's
/// session, answered from a stub — is asked "what is today's session?",
/// and must CALL it and speak its answer.
///
/// Gated exactly the way `AppleMindLiveTests` is: on OS 26, then on the
/// model being READY, with a skip that says so. On the Mac this was
/// written on (2026-09-11, macOS 26.6.1) the model was NOT ready — the
/// vendor answered `modelNotReady` and every test here SKIPPED, saying
/// so (a first draft of this sentence said they ran; it was wrong, and
/// the per-test notes below were right). The first machine with the
/// model ready is the measurement.
///
/// The numbers printed here are the Mac half of AC-228 for this mind —
/// the round-trip wall time of a reply that calls a tool, and the
/// first-token latency with and without the tool in the session. The
/// phone rows are Ryad's gate (§172c), not a claim this Mac can make.
@Suite("live · AC-223 · the Apple mind asks the session tool",
       .timeLimit(.minutes(5)))
struct AppleToolLiveTests {

    /// A SKIP THAT SAYS SO (the 4h review's finding, applied here).
    private static func skipping(_ verdict: MindUnavailable) -> Bool {
        print("SKIPPED (\(verdict)) — an OS-26 machine with the on-device model ready makes this test REAL")
        return true
    }

    /// The stub's fixed sentence. Its DISTINCTIVE words — "tempo", "river
    /// loop", "push" — are what the reply is checked for: the model
    /// cannot know them unless the tool told it.
    private static let session =
        "Today's session is a forty minute tempo run on the river loop. Readiness verdict: push."

    private static let instructions =
        "You are speaking aloud to a runner. You have a tool that reads today's training "
        + "session. When asked about today's session, call the tool and repeat what it says "
        + "in one short sentence. No markdown, no lists."

    private static let question = "What is today's session?"

    /// One reply, timed: the whole round trip and the first token.
    private struct Timed {
        var text = ""
        var terminal: ReplyUpdate?
        var firstToken: Duration?
        var total: Duration = .zero
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func timedReply(_ generator: AppleReplyGenerator) async throws -> Timed {
        let clock = ContinuousClock()
        let start = clock.now
        let run = try await generator.openReply(to: ReplyContext(
            transcript: question,
            options: MultiModalKit.GenerationOptions(temperature: 0)))
        var timed = Timed()
        for await update in run.updates {
            switch update {
            case .token(let token):
                if timed.firstToken == nil { timed.firstToken = start.duration(to: clock.now) }
                timed.text += token
            case .finished, .failed:
                timed.terminal = update
            }
        }
        timed.total = start.duration(to: clock.now)
        return timed
    }

    /// AC-223: the tool is CALLED, and the reply carries its words.
    ///
    /// NOT YET OBSERVED. On the Mac this was written on (2026-09-11,
    /// macOS 26.6.1) the vendor answered `modelNotReady` and a bare
    /// generation threw `assetsUnavailable`, so every test in this suite
    /// SKIPPED, saying so. The expectations below are the interface's
    /// promise — a session handed one tool, asked the question its
    /// description answers, calls it — and the first machine with the
    /// model ready is the measurement. If the model proves to call a
    /// lone tool unreliably, the honest fix is to record the observed
    /// rate here and gate these two `#expect`s on it, not to delete them.
    @Test("the real mind calls the session tool and speaks its answer (AC-223)")
    func realMindCallsTheTool() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let tool = ScriptedTool(name: "session", plan: .answers(Self.session))
        let generator = AppleReplyGenerator(
            instructions: Self.instructions,
            tools: ToolTable([ReplyTool(name: "session",
                                        description: "Reads today's training session and its readiness verdict.",
                                        call: tool.tool.call)]))
        // Warm the model outside the measured turn (AC-115): the number
        // below is the tool path's, not the cold start's.
        generator.prewarm()

        let reply = try await Self.timedReply(generator)
        print("AC-223 · tool called \(tool.calls.count)× · round trip \(reply.total) · "
            + "first token \(reply.firstToken.map { "\($0)" } ?? "n/a") · said: \(reply.text)")

        #expect(tool.calls.count >= 1, "the model did not call the tool; said: \(reply.text)")
        let said = reply.text.lowercased()
        #expect(said.contains("tempo") || said.contains("river"),
                "the reply does not carry the tool's words: \(reply.text)")
        #expect(reply.terminal == .finished(.unreported),
                "the vendor reports no stop reason (AC-235): \(String(describing: reply.terminal))")
    }

    /// AC-225 through the real session: a tool that THROWS. Today the
    /// adapter lets the throw through, the vendor ends the stream with
    /// its `ToolCallError`, and the run ends `.failed(.engine(_))` with
    /// the sentence every mind writes. That is the INTERIM ending — the
    /// vendor's interface allows the other one too (the adapter catches
    /// and answers the model with the sentence, and the model speaks),
    /// which is how the MLX run ends the same case. Which ending the
    /// Apple mind keeps is an open fork, Ryad's, written up at
    /// `AppleReplyRun.toolFailure`; this test pins the interim ending
    /// until the ruling changes it, so that a change is a visible red,
    /// never a silent drift. It has not yet run against a ready model
    /// (see `realMindCallsTheTool`).
    @Test("a throwing tool ends the real reply as the agreed failure (AC-225)")
    func throwingToolFailsTheReply() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let tool = ScriptedTool(name: "session", plan: .throwsError("the stub is offline"))
        let generator = AppleReplyGenerator(
            instructions: Self.instructions,
            tools: ToolTable([ReplyTool(name: "session",
                                        description: "Reads today's training session and its readiness verdict.",
                                        call: tool.tool.call)]))
        generator.prewarm()

        let reply = try await Self.timedReply(generator)
        print("AC-225 · tool called \(tool.calls.count)× · ended \(String(describing: reply.terminal)) · "
            + "said: \(reply.text)")
        #expect(tool.calls.count >= 1, "the model did not call the tool; said: \(reply.text)")
        #expect(reply.terminal == .failed(.engine("tool 'session' failed: the stub is offline")),
                "ended: \(String(describing: reply.terminal))")
    }

    /// AC-228's Mac half for this mind: the first token WITH the tool in
    /// the session against WITHOUT it, same question, same instructions,
    /// greedy. Printed, not asserted — a wall-clock number on a shared
    /// Mac is evidence for INSTRUMENTS, not a test's promise.
    @Test("first-token latency, with and without the tool in the session (AC-228, Mac half)")
    func firstTokenWithAndWithoutTheTool() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        if let verdict = AppleMind.readiness() { _ = Self.skipping(verdict); return }
        let tool = ScriptedTool(name: "session", plan: .answers(Self.session))
        let with = AppleReplyGenerator(
            instructions: Self.instructions,
            tools: ToolTable([ReplyTool(name: "session",
                                        description: "Reads today's training session and its readiness verdict.",
                                        call: tool.tool.call)]))
        let without = AppleReplyGenerator(instructions: Self.instructions)
        without.prewarm()

        // Three of each, interleaved, so a warm-up or a busy Mac does not
        // land on one side only.
        for round in 1...3 {
            let plain = try await Self.timedReply(without)
            let tooled = try await Self.timedReply(with)
            let plainFirst = plain.firstToken.map { "\($0)" } ?? "n/a"
            let tooledFirst = tooled.firstToken.map { "\($0)" } ?? "n/a"
            let withoutSide = "WITHOUT tool: first token \(plainFirst), total \(plain.total)"
            let withSide = "WITH tool: first token \(tooledFirst), total \(tooled.total), "
                + "called \(tool.calls.count)×"
            print("AC-228 · round \(round) · \(withoutSide) · \(withSide)")
            #expect(plain.terminal == .finished(.unreported))
            #expect(tooled.terminal == .finished(.unreported))
        }
    }
}
