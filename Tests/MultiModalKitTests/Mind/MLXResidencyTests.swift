// 5b piece 4: THE WARM'S END IS AN EVENT (AC-312; D-116 F-7 A, D-124 F-21 B).
//
//     prewarm() ── asked ──▶ a load begins ──▶ it ends ── resident ──▶ whenWarm() == true
//                                                     └─ not ─────▶ whenWarm() == false
//     resident already ─▶ true at once · nothing asked, nothing loading ─▶ false at once
//     cancelled ─▶ at once, with what is true then
//
// The poll this replaces is the diet app's: `prewarm()`, then up to
// 600 × 200 ms on `isResident`. The watch is proved on its own, with its
// four reports made by hand; the model's wiring is proved on a model with
// no weights (a real warm that fails at the door, no MLX call); a warm that
// SUCCEEDS needs real weights and is the live row, gated like every live
// MLX row.

import Foundation
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

@Suite("AC-312 · the warm's end is an event", .timeLimit(.minutes(1)))
struct MLXResidencyTests {

    /// A waiter, and the wait for it to have registered — the watch's own
    /// event, raced against a cap.
    static func waiting(on watch: WarmWatch) async -> (Task<Bool, Never>, Bool) {
        let before = watch.waitersSeen.count
        let task = Task { await watch.whenWarm() }
        let registered = await Wait4y.fact { _ = await watch.waitersSeen.wait(atLeast: before + 1) }
        return (task, registered)
    }

    /// The waiter's answer, or `nil` when the cap wins. The cap CANCELS
    /// the waiter — `whenWarm()` is cancellable, so a red row ends in
    /// seconds instead of parking a task on a warm that never ends.
    static func answer(_ task: Task<Bool, Never>, within deadline: Duration = .seconds(10)) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: deadline)
                task.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - the watch

    @Test("returns at once when the weights are already resident (AC-312)")
    func atOnceWhenResident() async {
        let watch = WarmWatch()
        watch.loadBegan()
        watch.loadEnded(resident: true)
        #expect(await watch.whenWarm() == true)
    }

    @Test("a waiter is answered true when the load in flight ends with the weights (AC-312)")
    func trueWhenTheWeightsArrive() async {
        let watch = WarmWatch()
        watch.asked()
        let (task, registered) = await Self.waiting(on: watch)
        #expect(registered, "a warm is asked for: the call WAITS, it does not answer at once")
        watch.loadBegan()
        watch.loadEnded(resident: true)
        #expect(await Self.answer(task) == true)
    }

    @Test("false when the warm ends without the weights — the spinner always stops (D-124 F-21 B)")
    func falseWhenTheWarmEndsWithout() async {
        let watch = WarmWatch()
        watch.asked()
        let (task, registered) = await Self.waiting(on: watch)
        #expect(registered)
        watch.loadBegan()
        watch.loadEnded(resident: false)
        watch.askEnded()
        #expect(await Self.answer(task) == false)
    }

    @Test("false at once when nothing is resident and nothing is loading (D-124 F-21 B)")
    func falseAtOnceWhenIdle() async {
        #expect(await WarmWatch().whenWarm() == false)
    }

    @Test("an ask keeps the answer waiting until its warm is over, not only a load (D-124 F-21 B)")
    func anAskAloneKeepsItWaiting() async {
        let watch = WarmWatch()
        watch.asked()
        #expect(watch.isWarming, "asked and not over is warming")
        let (task, registered) = await Self.waiting(on: watch)
        #expect(registered)
        watch.askEnded()
        #expect(await Self.answer(task) == false)
        #expect(!watch.isWarming)
    }

    @Test("cancellable: a cancelled wait returns at once, with what is true then (AC-312)")
    func cancellable() async {
        let watch = WarmWatch()
        watch.asked()
        let (task, registered) = await Self.waiting(on: watch)
        #expect(registered)
        task.cancel()
        #expect(await Self.answer(task) == false, "answered by the cancel — no load ever ended")
        #expect(watch.isWarming, "and the warm itself goes on: cancelling a wait cancels no work")
    }

    // Added at GREEN, each for a path no row above reached.

    @Test("resident while a warm is still asked for: true at once, not after the warm (AC-312)")
    func residentWinsOverAPendingAsk() async {
        let watch = WarmWatch()
        watch.asked()
        watch.loadBegan()
        watch.loadEnded(resident: true)
        #expect(await Self.answer(Task { await watch.whenWarm() }) == true)
    }

    @Test("a load in flight with no warm asked — a turn's own — is waited for too (AC-312)")
    func aTurnsOwnLoadIsWaitedFor() async {
        let watch = WarmWatch()
        watch.loadBegan()
        let (task, registered) = await Self.waiting(on: watch)
        #expect(registered)
        watch.loadEnded(resident: true)
        #expect(await Self.answer(task) == true)
    }

    @Test("after a retire the weights are gone: false at once (AC-312)")
    func aRetireAnswersFalse() async {
        let watch = WarmWatch()
        watch.loadBegan()
        watch.loadEnded(resident: true)
        watch.retired()
        #expect(await watch.whenWarm() == false)
    }

    // MARK: - the model's wiring (no weights: a real warm that fails at the door)

    static func modelWithoutWeights() -> LocalMindModel {
        LocalMindModel(weights: FileManager.default.temporaryDirectory
            .appending(path: "mmk-no-such-weights-\(UUID().uuidString)"),
            pressure: ScriptedPressureSource())
    }

    @Test("the model: nothing warming and nothing resident answers false at once (D-124 F-21 B)")
    func theModelAnswersFalseAtOnce() async {
        #expect(await Self.modelWithoutWeights().whenWarm() == false)
    }

    /// The model cannot be made resident without weights, so the load's
    /// report is made by hand — the retire is the model's own.
    @Test("the model's retire tells the watch: resident, retired, false (AC-312)")
    func theModelsRetireTellsTheWatch() async {
        let model = Self.modelWithoutWeights()
        model.warm.loadBegan()
        model.warm.loadEnded(resident: true)
        #expect(await model.whenWarm() == true)
        await model.retire()
        #expect(await model.whenWarm() == false)
    }

    @Test("the model's warm consumes its ask: a warm that fails at the door answers its waiter false (AC-312)")
    func theModelsWarmAnswersItsWaiter() async {
        let model = Self.modelWithoutWeights()
        model.warm.asked()   // what `MLXReplyGenerator.prewarm()` does before its hop
        let (task, registered) = await Self.waiting(on: model.warm)
        #expect(registered, "the ask is raised: the waiter waits for the warm")
        await model.startPrewarm(instructions: nil, maxTokens: 1)
        #expect(await Self.answer(task) == false, "the weights are absent: the warm ended without them")
        #expect(!model.warm.isWarming)
    }
}

/// The claim that makes `prewarm(); await model.whenWarm()` safe is about
/// ORDER inside one function: the ask is raised before the hop to the
/// model's actor, so a `whenWarm()` right after `prewarm()` can never find
/// "nothing loading" in the gap. A race cannot be asked for on cue, so the
/// order is read from the code — the AC-251 / AC-263 shape.
@Suite("AC-312 · prewarm() raises the ask before its hop",
       .enabled(if: MLXModuleSource.isReadable,
                "the MultiModalKitMLX sources are not readable from this run"))
struct MLXPrewarmOrderTests {

    @Test("in prewarm(), the ask comes before the Task that hops to the model")
    func theAskComesFirst() throws {
        let sources = try MLXModuleSource.files()
        // `MLXReplyGenerator.prewarm()` lives in LocalMind.swift, beside the
        // model it hops to; the model itself has no `public func prewarm()`.
        let text = try #require(sources["LocalMind.swift"])
        let start = try #require(text.range(of: "public func prewarm()"))
        let body = String(text[start.upperBound...].prefix(2_000))
        let ask = try #require(body.range(of: "model.warm.asked()"), "prewarm() must raise the ask")
        let hop = try #require(body.range(of: "Task {"), "prewarm() hops to the model")
        #expect(ask.lowerBound < hop.lowerBound, "the ask is raised BEFORE the hop")
    }
}

/// A warm that SUCCEEDS needs real weights: gated like every live MLX row
/// (`MMK_MLX_MODEL`, and the shader library — without it MLX aborts the
/// process instead of failing a test, AC-129).
@Suite("AC-312 · a real warm's end, when this machine has the model", .timeLimit(.minutes(5)))
struct MLXResidencyLiveTests {

    @Test("prewarm(), then whenWarm(): true once the real weights are resident — and at once after (AC-312)")
    func aRealWarmEnds() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"],
              FileManager.default.fileExists(atPath: dir), MLXRuntime.isAvailable else {
            print("SKIPPED (no MMK_MLX_MODEL or no shader library) — set MMK_MLX_MODEL and run "
                + "Scripts/metallib.sh to make this test REAL")
            return
        }
        let model = LocalMindModel(weights: URL(filePath: dir))
        let mind = try MLXReplyGenerator(model: model, maxTokens: 8)
        mind.prewarm()
        #expect(await model.whenWarm() == true, "the warm's end, as one await — no poll")
        #expect(await model.isResident)
        #expect(await model.whenWarm() == true, "already resident: at once")
        await model.retire()
    }
}
