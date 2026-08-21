import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// AC-128: a REAL token, from the REAL model, inside `swift test`.
///
/// Gated twice, on purpose, and the second gate is the one D-061 forced:
///
/// 1. `MMK_MLX_MODEL` must point at the weights — the house pattern for
///    "model required; skips if absent".
/// 2. `MLXRuntime.isAvailable` must be true. Without a `default.metallib`
///    MLX does not fail a test, it **aborts the process** — so this is
///    not politeness, it is the difference between a skipped test and a
///    dead runner that cannot say which test killed it (AC-129).
@Suite("AC-128/129 · the real model, when this machine has one",
       .timeLimit(.minutes(5)))
struct MLXMindLiveTests {

    private static var weights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A SKIP THAT SAYS SO.
    ///
    /// The 4h review's sharpest test finding: five of these six tests
    /// `return` early when the model is absent, and the runner prints
    /// "passed" — a skip indistinguishable from a proof. Swift Testing
    /// has no skip verb here, so the least dishonest thing available is
    /// to say it out loud, and to name what would make it run.
    private static func skipping(_ what: String) -> Bool {
        print("SKIPPED (\(what)) — set MMK_MLX_MODEL and run Scripts/metallib.sh to make this test REAL")
        return true
    }

    /// AC-129's control, and it runs on EVERY machine: the guard must be
    /// able to say whether it is switched on. A guard that silently
    /// answers "yes" everywhere is the lying instrument this project
    /// keeps finding.
    @Test("the runtime guard answers, and says WHERE it found the shaders")
    func theGuardCanSayWhetherItIsOn() {
        let found = MLXRuntime.metallibURL()
        #expect(MLXRuntime.isAvailable == (found != nil),
                "isAvailable must agree with the artefact it claims to have found")
        if let found {
            #expect(FileManager.default.fileExists(atPath: found.path))
        }
    }

    @Test("the model reports honestly whether it is installed — asking triggers nothing")
    func askingNeverLoads() async throws {
        guard let weights = Self.weights else { _ = Self.skipping("no MMK_MLX_MODEL"); return }
        let model = LocalMindModel(weights: weights)
        #expect(model.modelInstalled(), "the weights and BOTH tokenizer files must be present")

        let absent = LocalMindModel(weights: weights.appending(path: "not-here"))
        #expect(absent.modelInstalled() == false)
    }

    @Test("a missing model is refused at the door, not discovered mid-reply")
    func theDoorRefusesWhatIsNotThere() async throws {
        guard let weights = Self.weights else { _ = Self.skipping("no MMK_MLX_MODEL"); return }
        let mind = MLXReplyGenerator(
            model: LocalMindModel(weights: weights.appending(path: "not-here")))
        await #expect(throws: MLXUnavailable.self) {
            _ = try await mind.openReply(to: "hello?")
        }
    }

    /// THE ONE THAT MATTERS. A real reply, from real weights, through the
    /// real seam — tokens, then exactly one terminal.
    @Test("a REAL reply: tokens then one terminal, and NO reasoning is spoken")
    func aRealReply() async throws {
        guard let weights = Self.weights, MLXRuntime.isAvailable else {
            _ = Self.skipping("no MMK_MLX_MODEL or no metallib"); return
        }
        let mind = MLXReplyGenerator(
            model: LocalMindModel(weights: weights),
            instructions: "You are speaking aloud. Answer in one short sentence. "
                + "No markdown, no lists.",
            maxTokens: 64)

        let clock = ContinuousClock()
        let start = clock.now
        let run = try await mind.openReply(to: "What is the capital of Italy?")
        var spoken = ""
        var terminals: [ReplyUpdate] = []
        var firstTokenAt: ContinuousClock.Instant?
        for await update in run.updates {
            switch update {
            case .token(let t):
                if firstTokenAt == nil { firstTokenAt = clock.now }
                spoken += t
            case .finished, .failed: terminals.append(update)
            }
        }

        #expect(terminals.count == 1, "exactly one terminal: \(terminals)")
        if case .failed(let why) = terminals.first {
            Issue.record("the real model failed: \(why)")
            return
        }
        #expect(!spoken.isEmpty, "a real reply has words in it")
        // §86's promise, checked against a real model rather than a script:
        // the reasoning must never have become a string.
        #expect(!spoken.contains("<think>"))
        #expect(!spoken.contains("</think>"))

        let ttft = firstTokenAt.map { start.duration(to: $0) }
        print("AC-128 · first token in \(ttft.map { "\($0)" } ?? "n/a") · said: \(spoken)")
    }

    /// The number the demo actually lives or dies by: how long the first
    /// word takes once the weights are already resident.
    @Test("WARM, the first token is fast — the cold 1.9 s is the load, not the model")
    func warmFirstToken() async throws {
        guard let weights = Self.weights, MLXRuntime.isAvailable else {
            _ = Self.skipping("no MMK_MLX_MODEL or no metallib"); return
        }
        let model = LocalMindModel(weights: weights)
        let clock = ContinuousClock()

        let loadStart = clock.now
        _ = try await model.ensureModel()
        let load = loadStart.duration(to: clock.now)

        let mind = MLXReplyGenerator(model: model,
                                     instructions: "Answer in one short sentence.",
                                     maxTokens: 32)
        let askStart = clock.now
        let run = try await mind.openReply(to: "What is the capital of France?")
        var first: ContinuousClock.Instant?
        var spoken = ""
        for await update in run.updates {
            if case .token(let t) = update {
                if first == nil { first = clock.now }
                spoken += t
            }
        }
        let ttft = askStart.duration(to: first ?? clock.now)
        print("AC-128 WARM · model load \(load) · first token \(ttft) · said: \(spoken)")
        #expect(!spoken.isEmpty)
        #expect(!spoken.contains("<think>"))
    }

    /// PARTIALLY closes the review's "the gate is never proven WIRED"
    /// finding: nothing in the suite constructed the real `MLXTokenSource`
    /// at all, so even its door was unproven. This constructs it and
    /// exercises the door on EVERY machine — no weights, no metallib, no
    /// GPU — which is the half that needs no hardware.
    ///
    /// The other half (a defiant `<think>` from the real model reaching
    /// the real detokenizer) still needs weights AND a model that ignores
    /// `enable_thinking`, and stays open in D-063.
    @Test("the REAL source is wired to the door — it refuses what is not installed")
    func theRealSourceRefusesAtTheDoor() {
        let absent = LocalMindModel(weights: URL(filePath: "/nowhere/no-model"))
        let source = MLXTokenSource(model: absent, instructions: nil, maxTokens: 8)
        guard let refusal = source.unavailable else {
            Issue.record("a source with no weights must refuse at the door")
            return
        }
        // The reason must be SPECIFIC. "Something went wrong" would pass a
        // weaker assertion and tell a person nothing.
        #expect(refusal is MLXUnavailable)
        #expect(String(describing: refusal).isEmpty == false)
    }

    @Test("a cancelled REAL reply ends without a terminal")
    func aRealCancel() async throws {
        guard let weights = Self.weights, MLXRuntime.isAvailable else {
            _ = Self.skipping("no MMK_MLX_MODEL or no metallib"); return
        }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights),
                                     maxTokens: 256)
        let run = try await mind.openReply(to: "Count slowly from one to fifty.")
        await run.cancel()
        guard let updates = await ReplyConformanceKit.drainBounded(run) else {
            Issue.record("a cancelled reply's stream must END"); return
        }
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty)
    }
}
