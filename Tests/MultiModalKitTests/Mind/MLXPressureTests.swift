import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// PRESSURE ABANDONS THE GENERATION (4y, SPEC §187/3, AC-261..AC-263,
// D-107 F-3 = A).
//
// Aura's R3: a memory warning arriving while a generation runs. The
// library reported it and nothing acted. Now `.warning` CANCELS every
// live run through its own ticket — the stream ends with no terminal,
// the way a barge ends one — and frees the prefill; `.critical` retires
// the weights too, and the next `openReply` reloads them (R4). The
// HANDLER does no work: one hop to the actor, proven by reading its
// source (AC-263). Every row pushes levels by hand through a scripted
// source; the memory numbers are the live suite's (`MLXAdmissionLiveTests`).

@Suite("AC-261 / AC-262 · a memory warning ends the generation with no terminal", .timeLimit(.minutes(1)))
struct MLXPressureTests {

    /// A model with no weights on disk and a scripted pressure source,
    /// and a scripted generation REGISTERED on that model's runs — so a
    /// level the test pushes reaches a run the test can read.
    private struct Rig {
        let pressure = ScriptedPressureSource()
        let model: LocalMindModel
        let source: ScriptedTokenSource
        let mind: MLXReplyGenerator

        init(_ plan: ScriptedTokenSource.Plan = .tokensThenHold(["two", " tokens"])) {
            let model = LocalMindModel(
                weights: URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-4y-\(UUID().uuidString)"),
                headroom: { .unavailable(.noMemoryLimitOnThisPlatform) },
                pressure: pressure)
            self.model = model
            self.source = ScriptedTokenSource(plan, liveRuns: model.liveRuns)
            self.mind = MLXReplyGenerator(source: source)
        }
    }

    // MARK: AC-261: .warning cancels through the ticket, no terminal

    @Test("a .warning mid-generation ends the run's stream with NO terminal and no later token")
    func aWarningEndsTheRunWithNoTerminal() async throws {
        let rig = Rig()
        let facts = Facts()
        let run = try await rig.mind.openReply(to: "a thought under pressure")
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 2"), "the generation is in flight before the kernel speaks")
        #expect(rig.model.liveRuns.count == 1, "the run registered itself at birth")

        rig.pressure.push(.warning)
        #expect(await Wait4y.handled(.warning, on: rig.model), "the actor acted on the level")

        let updates = try await Wait4y.settled(story)
        #expect(updates == [.token("two"), .token(" tokens")],
                "the two tokens already spoken, then the end — no terminal, like a barge")
        #expect(await Wait4y.fact { await rig.source.cancellationSeen() },
                "the generation was cancelled — the optimisation that frees the prefill")
        #expect(rig.model.liveRuns.count == 0, "the abandoned run left the registry")
        #expect(await rig.model.retirements == 0, "a warning does NOT retire the weights")
    }

    /// F-3 = A's second half: the NEXT turn runs clean. A run born after
    /// the warning is not touched by it.
    @Test("a run opened AFTER the warning runs clean")
    func theNextTurnRunsClean() async throws {
        let rig = Rig(.tokens(["clean"]))
        rig.pressure.push(.warning)
        #expect(await Wait4y.handled(.warning, on: rig.model))
        let run = try await rig.mind.openReply(to: "the next turn")
        let updates = await ReplyConformanceKit.drain(run)
        #expect(updates == [.token("clean"), .finished(.unreported)])
    }

    /// Every live run, not the latest one: two generations on the same
    /// weights both end.
    @Test("a warning ends EVERY live run on the weights")
    func aWarningEndsEveryLiveRun() async throws {
        let rig = Rig()
        let facts = Facts()
        let first = try await rig.mind.openReply(to: "first")
        let second = try await rig.mind.openReply(to: "second")
        let firstStory = ReplyStory.collect(first, facts: facts)
        let secondStory = ReplyStory.collect(second, facts: Facts())
        #expect(rig.model.liveRuns.count == 2)
        rig.pressure.push(.warning)
        #expect(await Wait4y.handled(.warning, on: rig.model))
        #expect(ReplyConformanceKit.terminals(in: try await Wait4y.settled(firstStory)).isEmpty)
        #expect(ReplyConformanceKit.terminals(in: try await Wait4y.settled(secondStory)).isEmpty)
        #expect(rig.model.liveRuns.count == 0)
    }

    /// `.normal` is the kernel saying the pressure LIFTED — nothing ends.
    @Test(".normal does nothing: the generation keeps running")
    func normalDoesNothing() async throws {
        let rig = Rig()
        let facts = Facts()
        let run = try await rig.mind.openReply(to: "a thought")
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 2"))
        rig.pressure.push(.normal)
        #expect(await Wait4y.handled(.normal, on: rig.model))
        #expect(!(await facts.heard("ended", within: .milliseconds(100))), "still running")
        #expect(rig.model.liveRuns.count == 1)
        await run.cancel()
        _ = try await Wait4y.settled(story)
    }

    /// A run that ended on its own is not in the registry any more — the
    /// warning finds nothing, and the weights are untouched.
    @Test("a run that finished leaves the registry, and a later warning finds nothing")
    func aFinishedRunIsNotInTheRegistry() async throws {
        let rig = Rig(.tokens(["done"]))
        let run = try await rig.mind.openReply(to: "quick")
        _ = await ReplyConformanceKit.drain(run)
        #expect(rig.model.liveRuns.count == 0)
        #expect(rig.model.liveRuns.abandonAll() == 0)
    }

    // MARK: AC-262: .critical retires the weights as well

    @Test("a .critical ends the run AND retires the weights; the next reply opens again")
    func aCriticalRetiresTheWeights() async throws {
        let rig = Rig()
        let facts = Facts()
        let run = try await rig.mind.openReply(to: "a thought under critical pressure")
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 2"))

        rig.pressure.push(.critical)
        #expect(await Wait4y.handled(.critical, on: rig.model))

        let updates = try await Wait4y.settled(story)
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty, "no terminal, as for a warning")
        #expect(await rig.model.retirements == 1, "and the weights were let go")
        #expect(await rig.model.isResident == false)
        // R4: non-terminal. The door opens again for the next turn —
        // the RELOAD behind it is the live suite's row, since this Mac
        // has no weights to reload.
        let next = try await rig.mind.openReply(to: "the next turn")
        await next.cancel()
    }

    @Test("a .critical with nothing running still retires — the weights, not the run, are the target")
    func aCriticalWithNoRunStillRetires() async throws {
        let rig = Rig()
        rig.pressure.push(.critical)
        #expect(await Wait4y.handled(.critical, on: rig.model))
        #expect(await rig.model.retirements == 1)
    }

    // MARK: the subscription's lifetime

    @Test("the model subscribes once at birth and cancels when it dies")
    func theSubscriptionLivesAsLongAsTheModel() async throws {
        let pressure = ScriptedPressureSource()
        do {
            let model = LocalMindModel(
                weights: URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-4y-\(UUID().uuidString)"),
                pressure: pressure)
            #expect(pressure.subscriptions == 1)
            #expect(pressure.cancellations == 0)
            _ = await model.isResident
        }
        #expect(pressure.cancellations == 1, "deinit let the source go")
        // And a level pushed after the model died goes nowhere — the
        // handler is gone, not dangling.
        pressure.push(.critical)
    }

    /// The real source builds a kernel dispatch source and lets it go on
    /// cancel — exercised once so a Mac says it can, without asserting
    /// anything about the kernel's mood.
    @Test("the system source subscribes and cancels without a level ever arriving")
    func theSystemSourceSubscribesAndCancels() {
        let subscription = SystemMemoryPressureSource().subscribe { _ in }
        subscription.cancel()
        subscription.cancel()   // idempotent
    }
}

// MARK: - AC-263: the handler does no work, by structure

/// The 4x suspend test's shape (AC-251): a claim about the code is read
/// FROM the code. A counting allocator is out of reach, so the closure
/// the model hands the pressure source is scanned between its two
/// markers and must contain exactly the hop and nothing else — no
/// `await` of its own, no MLX call, no retire, no clear. Aura's R3 in
/// one sentence: the handler raises the flag and returns.
@Suite("AC-263 · the pressure handler is one hop and nothing else",
       .enabled(if: MLXModuleSource.isReadable,
                "the MultiModalKitMLX sources are not readable from this run"))
struct MLXPressureHandlerScanTests {

    static let hop = "Task { await self?.pressure(level) }"

    @Test("between its markers the handler is the one hop: no await of its own, no MLX call, no work")
    func theHandlerIsOneHop() throws {
        let sources = try MLXModuleSource.files()
        let model = try #require(sources["LocalMind.swift"], "the model is where the handler lives")
        let begin = try #require(model.range(of: "// pressure-handler: begin"), "the begin marker must exist")
        let end = try #require(model.range(of: "// pressure-handler: end"), "the end marker must exist")
        #expect(begin.upperBound < end.lowerBound)
        let handler = String(model[begin.upperBound..<end.lowerBound])

        #expect(handler.components(separatedBy: Self.hop).count == 2,
                "the hop appears exactly once, spelled exactly so: \(handler)")
        let rest = handler.replacingOccurrences(of: Self.hop, with: "")
        for forbidden in ["await", "MLX.", "clearCache", "retire", "abandon", "freePrefill",
                          "Memory", "withLock", "DispatchQueue", "sleep"] {
            #expect(!rest.contains(forbidden),
                    "the handler does no work: `\(forbidden)` must not appear outside the hop — \(rest)")
        }
        #expect(handler.contains("[weak self]"), "the source must not keep a model alive")
    }

    /// The other half: the model is the ONLY place that hands the source
    /// a handler, so the scan above covers every subscription this module
    /// makes.
    @Test("the model is the only subscriber in the module")
    func theModelIsTheOnlySubscriber() throws {
        let sources = try MLXModuleSource.files()
        let subscribers = sources.filter { $0.value.contains(".subscribe {") || $0.value.contains(".subscribe(") }
            .map(\.key).sorted()
        #expect(subscribers == ["LocalMind.swift"], "\(subscribers)")
    }
}
