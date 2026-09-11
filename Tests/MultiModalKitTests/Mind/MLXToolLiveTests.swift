import Foundation
import MLXLMCommon
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-222 against the REAL model: the local mind is given Aura's session
/// read (F-3 = C), asked for today's session, and must CALL the tool and
/// speak its answer. Gated exactly as `MLXContractLiveTests` is — on
/// `MMK_MLX_MODEL` and on `MLXRuntime.isAvailable` — because without a
/// metallib MLX aborts the process (D-061), and a skip that says so is
/// the least dishonest thing available.
///
/// WHAT A 0.6B MODEL CAN BE RELIED ON TO DO, measured before this row
/// was written (eight prompt shapes, then the passing one three times
/// greedy and twice at the vendor's temperature; the run's own record
/// is printed by each test):
///
/// - It calls `session` when the USER'S turn names the tool ("use the
///   session tool…") and there is NO system instruction: 3/3 greedy,
///   2/2 at 0.6, every reply carrying the answer's numbers.
/// - It does NOT call when only a system instruction asks it to —
///   "always call the session tool", "you MUST first call…" — 0/4; it
///   answers "I don't have access to today's session".
/// - It does NOT call when ANY app instruction is present beside the
///   naming question, even "answer in one sentence of plain prose":
///   0/3 — it parrots the question back.
///
/// So this row uses the shape that holds, under greedy so the same
/// prompt gives the same bytes (AC-234) and a pass is a fact, not a
/// hope. What is NOT claimed, and is the honest finding for the
/// contract milestone: on this size the tool is a thing the PERSON
/// must ask for by name, and the app's instruction (D-027) and the tool
/// do not yet coexist. The spike's question (§169/2) is narrower — the
/// call crosses the seam and the reply continues — and that is what
/// this row proves on real weights.
@Suite("4w · AC-222: the local mind asks the session tool and speaks the answer, when this machine has the model",
       .timeLimit(.minutes(5)), .serialized)
struct MLXToolLiveTests {

    private static var weights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The gate, and the reason the skip is loud (the 4h review): a
    /// silent early return prints "passed" for a proof that never ran.
    private static func live() -> URL? {
        guard let weights, MLXRuntime.isAvailable else {
            print("SKIPPED (no MMK_MLX_MODEL or no metallib) — set MMK_MLX_MODEL and run "
                  + "Scripts/metallib.sh to make this test REAL")
            return nil
        }
        return weights
    }

    /// The stub Aura would own (§168a): a fixed session with a readiness
    /// verdict. The numbers are the distinctive words the reply must
    /// carry — no question about a training session produces "40" and
    /// "71" by accident.
    private static let session = "Today is a 40 minute easy run, readiness 71."
    /// The question NAMES the tool, and no instruction is given: the
    /// only shape the 0.6B weights follow (the suite note).
    private static let question = "Use the session tool to find out what today's session is."
    /// The 4r question, for the prefill row: the spec's cost is the same
    /// whatever the person asks.
    private static let plainQuestion = "What is today's session?"
    private static let spoken = "Answer in one short sentence of plain prose. No markdown, no lists."

    // MARK: - AC-222: the call is made and the answer is spoken

    @Test("the REAL model calls `session` and its reply carries the session's numbers")
    func theModelCallsTheToolAndSpeaksTheAnswer() async throws {
        guard let weights = Self.live() else { return }
        let clock = ContinuousClock()
        let calls = Mutex<[[String: String]]>([])
        let calledAt = Mutex<ContinuousClock.Instant?>(nil)
        let tool = ReplyTool(name: "session",
                             description: "Read today's training session and readiness.") { arguments in
            calls.withLock { $0.append(arguments) }
            calledAt.withLock { $0 = clock.now }
            return Self.session
        }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights),
                                     tools: ToolTable([tool]))
        // Warm first, so the numbers below are the tool path's and not
        // the metal pipeline's first breath (INSTRUMENTS §25).
        _ = try await mind.reply(to: ReplyContext(transcript: "hi", options: GenerationOptions(maxTokens: 1)))

        let started = clock.now
        var text = ""
        var firstWordAfterAnswer: ContinuousClock.Instant?
        var stop = StopReason.unreported
        let run = try await mind.openReply(to: ReplyContext(
            transcript: Self.question, options: GenerationOptions(temperature: 0)))
        for await update in run.updates {
            switch update {
            case .token(let token):
                text += token
                if firstWordAfterAnswer == nil, calledAt.withLock({ $0 }) != nil {
                    firstWordAfterAnswer = clock.now
                }
            case .finished(let reason): stop = reason
            case .failed(let failure): Issue.record("the reply failed: \(failure)")
            }
        }
        let ended = clock.now

        let made = calls.withLock { $0 }
        print("AC-222 live · calls: \(made)")
        print("AC-222 live · said: \(text)")
        print("AC-222 live · stop: \(stop)")
        print("AC-222 live · whole reply \(started.duration(to: ended))")
        if let calledAt = calledAt.withLock({ $0 }), let firstWordAfterAnswer {
            print("AC-222 live · question→call \(started.duration(to: calledAt)), "
                  + "call→first word after the answer \(calledAt.duration(to: firstWordAfterAnswer))")
        }
        #expect(made.count == 1, "the tool was called exactly once")
        #expect(made.first == [:], "the spike's read takes no arguments")
        #expect(stop == .complete)
        #expect(text.contains("40") && text.contains("71"),
                "the reply carries the session's numbers — the answer went back and was spoken")
        #expect(!text.contains("<tool_call>"), "the call's JSON is never spoken")
    }

    /// The same weights, no tool, the plain question — the Mac's
    /// baseline for the round trip above (AC-228's phone row is Ryad's,
    /// §172c). Printed, not asserted: a wall-clock number is evidence,
    /// not a contract.
    @Test("the no-tool baseline for the same weights is measured beside it")
    func theNoToolBaselineIsMeasured() async throws {
        guard let weights = Self.live() else { return }
        let clock = ContinuousClock()
        let bare = MLXReplyGenerator(model: LocalMindModel(weights: weights))
        _ = try await bare.reply(to: ReplyContext(transcript: "hi", options: GenerationOptions(maxTokens: 1)))
        let started = clock.now
        let reply = try await bare.reply(to: ReplyContext(
            transcript: Self.plainQuestion, options: GenerationOptions(maxTokens: 32, temperature: 0)))
        print("AC-228 live · no tool, plain question: \(started.duration(to: clock.now)) · said: \(reply.text)")
        #expect(!reply.text.isEmpty)
    }

    // MARK: - AC-228, the Mac half: what the spec costs to prefill

    /// The prompt with the tool's spec rendered, against the same prompt
    /// without it — the vendor's own token count and the decoded text's
    /// character count, so §58b's per-character slope applies. The phone
    /// number is Ryad's gate (§172c); this is the Mac harness that runs
    /// first.
    @Test("the spec's prefill cost is measured: tokens and characters, with and without the tool")
    func theSpecsPrefillIsMeasured() async throws {
        guard let weights = Self.live() else { return }
        let model = LocalMindModel(weights: weights)
        let container = try await model.ensureModelLoaded()
        let tool = ReplyTool(name: "session",
                             description: "Read today's training session and readiness.") { _ in Self.session }
        let specs = ToolTable([tool]).toolSpecs
        let spoken = Self.spoken
        let question = Self.plainQuestion

        func size(tools: [ToolSpec]?) async throws -> (tokens: Int, characters: Int) {
            try await container.perform { (model: ModelContext) in
                let input = try await model.processor.prepare(input: UserInput(
                    chat: MLXTokenSource.messages(spoken: spoken, asked: question, past: []),
                    tools: tools,
                    additionalContext: ["enable_thinking": false]))
                let ids = input.text.tokens.asArray(Int.self)
                return (ids.count, model.tokenizer.decode(tokenIds: ids).count)
            }
        }
        let without = try await size(tools: nil)
        let with = try await size(tools: specs)
        print("AC-228 prefill · without the spec: \(without.tokens) tokens / \(without.characters) chars; "
              + "with: \(with.tokens) tokens / \(with.characters) chars; "
              + "the spec adds \(with.tokens - without.tokens) tokens / \(with.characters - without.characters) chars")
        #expect(with.tokens > without.tokens, "the spec is IN the prompt")
        #expect(ToolTable.empty.toolSpecs == nil, "and no spec means the prompt of 4r, byte for byte")
    }
}
