// ADMISSION AND HEAT — THE SEAM HALF (4y, SPEC §186–§191, D-107).
//
// Two of D-107's four rulings are shapes the SEAM carries, and this file
// proves them with the scripted mind before any real mind implements the
// clock or reads the thermometer:
//
// - F-2 = A: `openReply` asks a thermal policy BEFORE opening a run, and
//   the default refuses at `.critical` only, with a typed, countable
//   `ReplyFailure.tooHot` (AC-260). D-028's one question, asked at a
//   SECOND moment — the transcription policy is untouched.
// - F-4 = A: a deadline is how a reply ENDS — `.finished(.deadline)` with
//   what was said so far — never a failure (AC-264; D-104 already ruled
//   that an ending is not a failure). The scripted mind's CLOCK makes
//   the ending: `GenerationOptions.deadline` is slept on an injected
//   `ManualClock`, and advancing it is what ends the slow reply. The
//   coordinator treats the ending exactly as it treats `.tokenBudget`.
//
// And AC-265's negative: the coordinator passes NO deadline and NO
// policy, so the voice path is byte-for-byte what it was — proven on the
// record (the options every driven call carried) and in the coordinator's
// own source (it has no seam a policy or a deadline could travel through).
//
// **Nothing here polls** (§3.3). The seam-half tests wait on an EVENT the
// wrapper sends, raced against a SLEEPING deadline, and park on the
// clock's own `waitForSleepers` (raced the same way) before they advance it; the
// coordinator-half tests ride `ToolSpikeTests.Rig` — a `ManualClock`
// bench whose events become names a test awaits, `opened:N` among them —
// and are `.serialized` for the reason that file gives. A deadline test
// never touches wall time.

import Foundation
import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

// MARK: - the seam half: policy, door, ending

@Suite(.timeLimit(.minutes(1)))
struct AdmissionSeamTests {

    // MARK: AC-260 — the default policy's table, pinned

    /// F-2 = A, exactly: `.critical` refuses and nothing else does. The
    /// measured phone reached `.serious` in every session and stayed
    /// there (INSTRUMENTS §26), so a default that refused at `.serious`
    /// would refuse every second turn — that is the row this test keeps
    /// honest.
    ///
    /// THE TABLE IS COMPLETE BY THE COMPILER (the enum tests' pattern
    /// below): `ThermalState` is not `CaseIterable`, so the four rows are
    /// listed by hand — and then switched over with no `default`, so a
    /// fifth state added later stops this file compiling instead of
    /// sitting silently outside the pinned table.
    @Test("DefaultGenerationThermalPolicy refuses at .critical only (F-2 = A)")
    func defaultPolicyRefusesOnlyAtCritical() {
        let policy = DefaultGenerationThermalPolicy()
        let every: [ThermalState] = [.nominal, .fair, .serious, .critical]
        for state in every {
            switch state {
            case .nominal, .fair, .serious, .critical:
                break
            }
        }
        let allowed = every.filter { policy.allowGeneration(thermal: $0) }
        #expect(allowed == [.nominal, .fair, .serious], "the measured phone lives at .serious")
        #expect(every.filter { !policy.allowGeneration(thermal: $0) } == [.critical],
                "one row refuses, and it is the last one")
    }

    /// The transcription policy is NOT this policy (D-028, D-107): it still
    /// refuses from `.serious` up. Both tables side by side, so the day
    /// someone "unifies" them, this line says which ruling they broke.
    @Test("the transcription policy's table is untouched — D-028 stands")
    func transcriptionPolicyIsUntouched() {
        let transcription = ConservativeThermalPolicy()
        let generation = DefaultGenerationThermalPolicy()
        #expect(!transcription.allowSettlingDecode(thermal: .serious, activeSettlingDecodes: 0))
        #expect(generation.allowGeneration(thermal: .serious),
                "two moments, two tables: the settling decode is optional work, a reply is the turn")
    }

    // MARK: AC-260 — the door

    @Test("openReply opens at .nominal, .fair and .serious (AC-260)")
    func doorOpensBelowCritical() async throws {
        for state in [ThermalState.nominal, .fair, .serious] {
            let thermometer = ScriptedThermalProvider(initial: state)
            let mind = ScriptedReplyGenerator(plans: [.manual()], thermal: thermometer)
            let run = try await mind.openReply(to: "a thought at \(state)")
            #expect(mind.repliesOpened == 1, "at \(state) the door opens")
            #expect(mind.heatRefusals.isEmpty)
            await run.cancel()
        }
    }

    @Test("openReply throws ReplyFailure.tooHot(.critical) at the door, and opens no run (AC-260)")
    func doorRefusesAtCritical() async {
        let thermometer = ScriptedThermalProvider(initial: .critical)
        let mind = ScriptedReplyGenerator(plans: [.manual()], thermal: thermometer)
        await #expect(throws: ReplyFailure.tooHot(.critical)) {
            _ = try await mind.openReply(to: "a thought on a hot phone")
        }
        #expect(mind.repliesOpened == 0, "a refused door consumes no plan and opens no run")
        #expect(mind.heatRefusals == [.critical], "the refusal is on the record, with the state")
    }

    /// The policy is the APP's (the shape `ThermalPolicy` has): a stricter
    /// one refuses where the default would not, so the default is a
    /// default, not a law.
    @Test("an injected policy overrules the default: refusing at .serious")
    func injectedPolicyOverrulesTheDefault() async {
        struct Stricter: GenerationThermalPolicy {
            func allowGeneration(thermal: ThermalState) -> Bool { thermal < .serious }
        }
        let thermometer = ScriptedThermalProvider(initial: .serious)
        let mind = ScriptedReplyGenerator(plans: [.manual()], thermal: thermometer,
                                          thermalPolicy: Stricter())
        await #expect(throws: ReplyFailure.tooHot(.serious)) {
            _ = try await mind.openReply(to: "a thought")
        }
        #expect(mind.repliesOpened == 0)
    }

    /// AC-236's counting caller, the way Aura will count heat: three
    /// attempts, the thermometer moved between them, and the failures a
    /// whole-reply caller catches are VALUES — two of them `.tooHot`.
    @Test("a counting caller sees two .tooHot across three attempts (AC-260, the AC-236 shape)")
    func twoHeatRefusalsCountAsTwo() async throws {
        let thermometer = ScriptedThermalProvider(initial: .critical)
        let inner = ScriptedReplyGenerator(plans: [.manual()], thermal: thermometer)
        var caught: [ReplyFailure] = []
        var answered = 0
        for state in [ThermalState.critical, .fair, .critical] {
            thermometer.push(state)
            let (mind, signals) = Self.announcing(inner)
            let task = Task { try await mind.reply(to: ReplyContext(transcript: "again")) }
            if state == .fair {
                // The one that opens: drive it to an ending, then count.
                #expect(await signals.heard("opened"))
                inner.emit(reply: 0, token: "cool enough")
                inner.finish(reply: 0)
            }
            do {
                _ = try await Self.settled(task)
                answered += 1
            } catch let failure as ReplyFailure {
                caught.append(failure)
            }
        }
        #expect(caught == [.tooHot(.critical), .tooHot(.critical)])
        #expect(caught.filter { if case .tooHot = $0 { true } else { false } }.count == 2)
        #expect(answered == 1)
        #expect(inner.heatRefusals == [.critical, .critical], "the mind's own count agrees")
    }

    @Test("tooHot describes itself in plain words, naming the state")
    func tooHotDescribesItself() {
        #expect(ReplyFailure.tooHot(.critical).description
                == "the device is too hot to generate — thermal state critical")
        #expect(ReplyFailure.tooHot(.serious).description.contains("serious"),
                "an app policy may refuse earlier; the sentence must still say where")
    }

    // MARK: AC-264 — a deadline is an ending

    @Test("GenerationOptions.deadline defaults to nil and is a value (AC-264, AC-265)")
    func deadlineOption() {
        #expect(GenerationOptions().deadline == nil, "nil = no deadline, the voice path's setting")
        #expect(GenerationOptions(deadline: .milliseconds(200)).deadline == .milliseconds(200))
        #expect(GenerationOptions(deadline: .milliseconds(200)) != GenerationOptions())
        #expect(GenerationOptions(deadline: .milliseconds(200)) == GenerationOptions(deadline: .milliseconds(200)))
    }

    /// AC-264's first clause, and F-4 = A: `GenerationOptions.deadline`
    /// ENDS a slow scripted reply. Two tokens are said, nobody finishes
    /// the reply by hand, and the CLOCK is advanced past the deadline —
    /// that alone ends the run, and `reply(to:)` RETURNS the partial text
    /// with `.deadline`, the way a `.tokenBudget` reply comes back
    /// (`ReplyContractTests.tokenBudgetStopRoundTrips`); it does not throw.
    ///
    /// The clock is a `ManualClock` and the deadline is a MINUTE: a mind
    /// that ignored the option never goes to sleep on the clock (red in
    /// ten seconds, at `parked`), and a mind that slept on wall time
    /// would never settle — the manual clock's minute passes in no time
    /// at all, the wall's does not. Only the injected clock makes this
    /// green. The test parks on the clock's own `waitForSleepers` before
    /// advancing, so the advance can never race ahead of the sleep it is
    /// meant to end (§3.3: an event, not a hope) — raced against a
    /// sleeping cap, because the first draft of this test parked FOREVER
    /// under mutation and held a run for ten minutes.
    @Test("GenerationOptions.deadline ends a slow reply on the injected clock — Reply(partial, .deadline) (AC-264)")
    func deadlineEndsASlowReplyOnTheInjectedClock() async throws {
        let clock = ManualClock()
        let (mind, signals) = Self.announcing(
            ScriptedReplyGenerator(plans: [.manual()], clock: clock))
        let task = Task {
            try await mind.reply(to: ReplyContext(transcript: "a long story",
                                                  options: GenerationOptions(deadline: .seconds(60))))
        }
        #expect(await signals.heard("opened"))
        mind.emit(reply: 0, token: "Once upon")
        mind.emit(reply: 0, token: " a time")
        #expect(await Self.parked(clock), "the run is asleep on the deadline, on THIS clock")
        await clock.advance(by: .seconds(60))
        let reply = try await Self.settled(task)
        #expect(reply == Reply(text: "Once upon a time", stop: .deadline),
                "what was said so far, and why it stopped — returned, not thrown")
        #expect(mind.record(ofReply: 0)?.context.options.deadline == .seconds(60),
                "the deadline travelled with the context, for the real minds to read")
        #expect(clock.sleeperCount == 0, "the ended reply holds no sleeper")
    }

    /// The other side of the same clock: a reply that ENDS before its
    /// deadline is not touched by it. The clock is never advanced, the
    /// hand finishes the reply, and the stop is `.complete` — and the
    /// sleeper the deadline parked is released the moment the reply ends,
    /// so a `ManualClock` is not left holding a dead reply's clock.
    @Test("a reply finished before its deadline ends .complete, and releases the clock's sleeper (AC-264)")
    func deadlineNotReachedLeavesTheEndingAlone() async throws {
        let clock = ManualClock()
        let (mind, signals) = Self.announcing(
            ScriptedReplyGenerator(plans: [.manual()], clock: clock))
        let task = Task {
            try await mind.reply(to: ReplyContext(transcript: "a short story",
                                                  options: GenerationOptions(deadline: .seconds(60))))
        }
        #expect(await signals.heard("opened"))
        #expect(await Self.parked(clock), "the deadline is asleep on the clock before the hand ends the reply")
        mind.emit(reply: 0, token: "The end.")
        mind.finish(reply: 0)
        let reply = try await Self.settled(task)
        #expect(reply == Reply(text: "The end.", stop: .complete), "the model's own ending, not the clock's")
        #expect(clock.sleeperCount == 0, "finishing by hand stopped the clock")
    }

    /// No deadline, no clock: the voice path's setting (AC-265's `nil`).
    /// The mind never sleeps, so there is nothing for an advance to wake —
    /// the reply stays open until a hand ends it, however far time moves.
    @Test("no deadline means no sleeper: the clock cannot end a reply that carries nil (AC-264, AC-265)")
    func noDeadlineArmsNoClock() async throws {
        let clock = ManualClock()
        let (mind, signals) = Self.announcing(
            ScriptedReplyGenerator(plans: [.manual()], clock: clock))
        let task = Task {
            try await mind.reply(to: ReplyContext(transcript: "take your time"))
        }
        #expect(await signals.heard("opened"))
        #expect(clock.sleeperCount == 0, "nil deadline: nothing was put to sleep on the clock")
        await clock.advance(by: .seconds(3600))
        mind.emit(reply: 0, token: "Still here.")
        mind.finish(reply: 0)
        let reply = try await Self.settled(task)
        #expect(reply == Reply(text: "Still here.", stop: .complete), "an hour later, the reply was still open")
    }

    // MARK: the enums — the compiler is the assertion

    /// THE COMPILER IS THE ASSERTION (the `ReplyContractTests` pattern):
    /// `StopReason` is now five cases, `.deadline` beside `.tokenBudget`.
    /// No `default` — add or remove a case and, under warnings-as-errors,
    /// this file stops compiling.
    @Test("StopReason is complete / tokenBudget / unreported / refused / deadline — F-4 = A")
    func stopReasonHasFiveCases() {
        let every: [StopReason] = [.complete, .tokenBudget, .unreported, .refused, .deadline]
        for stop in every {
            switch stop {
            case .complete, .tokenBudget, .unreported, .refused, .deadline:
                break
            }
        }
        #expect(every.map(String.init(describing:)).count == every.count)
        #expect(StopReason.deadline != .tokenBudget, "two clocks, two reasons: tokens and time")
        #expect(StopReason.deadline != .complete, "cut by the clock is not the model's own ending")
    }

    /// `ReplyFailure` gained `.tooHot(ThermalState)` and nothing else; a
    /// refusal is still NOT here (D-104).
    @Test("ReplyFailure gained .tooHot — and still has no .refused (D-104)")
    func replyFailureGainedTooHot() {
        let every: [ReplyFailure] = [.contextWindowExceeded,
                                     .unavailable(.weightsAbsent),
                                     .unsupportedLanguage,
                                     .busy,
                                     .tooHot(.critical),
                                     .engine("the rest")]
        for failure in every {
            switch failure {
            case .contextWindowExceeded, .unavailable, .unsupportedLanguage,
                 .busy, .tooHot, .engine:
                break
            }
        }
        #expect(every.map(String.init(describing:)).count == every.count)
        #expect(ReplyFailure.tooHot(.critical) == .tooHot(.critical))
        #expect(ReplyFailure.tooHot(.critical) != .tooHot(.serious), "the state is part of the value")
    }

    // MARK: - the event a test waits on (the ReplyContractTests shape)

    /// Waits for the FACT that a sleeper is parked on the clock — the
    /// clock's own event, raced against a SLEEPING cap so a red test dies
    /// in ten seconds. The loser is cancelled: `waitForSleepers` honours
    /// cancellation (it returns `false`), so nothing is left parked.
    private static func parked(_ clock: ManualClock, atLeast count: Int = 1,
                               within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await clock.waitForSleepers(atLeast: count) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func announcing(_ inner: ScriptedReplyGenerator) -> (AnnouncingMind, Signals) {
        let signals = Signals()
        return (AnnouncingMind(inner: inner, signals: signals), signals)
    }

    /// `Task.value` cannot be cancelled, so it is raced against a sleeping
    /// deadline — a suspension, never a spin — and the loser is cancelled.
    private static func settled<T: Sendable>(_ task: Task<T, any Error>,
                                             within deadline: Duration = .seconds(10)) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw WaitTimedOut(after: deadline)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let after: Duration
    var description: String { "the task did not settle within \(after)" }
}

private final class Signals: Sendable {
    private let stream: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation
    init() {
        (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }
    func send(_ name: String) { emit.yield(name) }
    func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await event in stream where event == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Says "opened" once the inner generator has handed a run back — the one
/// fact `reply(to:)` hides from a test. A refused door says nothing: the
/// throw is the event.
private struct AnnouncingMind: ReplyGenerating {
    let inner: ScriptedReplyGenerator
    let signals: Signals

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        let run = try await inner.openReply(to: context)
        signals.send("opened")
        return run
    }

    func emit(reply index: Int, token: String) { inner.emit(reply: index, token: token) }
    func finish(reply index: Int, stop: StopReason = .complete) { inner.finish(reply: index, stop: stop) }
    func record(ofReply index: Int) -> ScriptedReplyGenerator.ReplyRecord? { inner.record(ofReply: index) }
}

// MARK: - the coordinator half: the door and the ending, on the bench

/// The coordinator learned NOTHING in 4y — that is the claim. A heat
/// refusal takes the path a `.failOnOpen` takes today
/// (`TurnCoordinatorTests.generatorFailureEndsOnlyTheTurn`); a deadline
/// ending takes the path `.finished(.tokenBudget)` takes — the stop
/// reason is the text caller's concern, the mouth finishes what it has.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct AdmissionCoordinatorTests {
    typealias Rig = ToolSpikeTests.Rig

    /// A refused door is an honest failed turn: the failure event carries
    /// `tooHot`'s own words (AC-242's rule, unchanged), the next turn
    /// runs clean, and the memory is not poisoned — nothing was answered,
    /// so the ledger keeps the words and the memory refuses the exchange
    /// (AC-194, untouched).
    @Test("a .tooHot door fails the turn honestly; the next turn runs clean; memory is not poisoned")
    func heatRefusalFailsOnlyTheTurn() async throws {
        let thermometer = ScriptedThermalProvider(initial: .critical)
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.manual()], thermal: thermometer),
            synthesizer: .manual(utterances: 1))
        let refusal = ReplyFailure.tooHot(.critical)

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "the lost question", at: 0)
            #expect(await rig.heard("failed:0"), "the refusal must surface as a turn event")
            #expect(rig.bench.generator.repliesOpened == 0, "the door never opened a run")
            #expect(rig.bench.generator.heatRefusals == [.critical])
            #expect(await rig.bench.coordinator.currentMemory.isEmpty, "a failed turn is never remembered")

            // The phone cools; the next turn is untouched by the corpse.
            thermometer.push(.fair)
            rig.bench.speak(utterance: 1, final: "asking again", at: 96_000)
            #expect(await rig.heard("thinking:1"), "no stale ticket may block the next reply")
            await rig.completeManualTurn(1, reply: 0, utterance: 0, tokens: ("Cooler", " now."))
            #expect(await rig.bench.coordinator.currentMemory.map(\.replied) == ["Cooler now."])
            await rig.finish()
        }

        let second = rig.bench.generator.record(ofReply: 0)
        #expect(second?.transcript == "the lost question asking again",
                "nothing answered the first words, so the ledger keeps them (D-040 F-2)")
        #expect(second?.history.isEmpty == true, "and the memory does not also hold them")
        let expected: [TurnEvent] = [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .turnFailed(.generationFailed(refusal.description), turn: 0),
            .stateChanged(.idle, turn: 0),
            .stateChanged(.listening, turn: 1),
            .stateChanged(.thinking, turn: 1),
            .replyToken("Cooler", turn: 1),
            .replyToken(" now.", turn: 1),
            .stateChanged(.speaking, turn: 1),
            .turnCompleted(turn: 1),
            .stateChanged(.idle, turn: 1)
        ]
        #expect(await rig.bench.box.events == expected)
    }

    /// F-4 = A on the voice path: a reply the clock cut is SPOKEN as far
    /// as it got and the turn COMPLETES — the same events, in the same
    /// order, as a reply the token cap cut. Whatever was said is what the
    /// conversation remembers. The ending is scripted by hand here, on
    /// purpose: the coordinator passes no deadline (AC-265), so no clock
    /// can end a driven reply — this half proves what the coordinator
    /// DOES with the ending, and the seam half above proves the clock.
    @Test("a reply that ends .finished(.deadline) is spoken as far as it got and completes the turn (AC-264)")
    func deadlineEndingCompletesTheTurn() async throws {
        let rig = try await Rig(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "tell me a long story", at: 0)
            // `opened:0`, not `thinking:0`: the coordinator publishes
            // `thinking` BEFORE it awaits `openReply`, so an emit on
            // `thinking` could land in a reply with no record yet and
            // vanish (the 4y review caught exactly that flake).
            #expect(await rig.heard("opened:0"))
            rig.bench.generator.emit(reply: 0, token: "Once upon")
            rig.bench.generator.emit(reply: 0, token: " a time")
            #expect(await rig.heard("token: a time:0"))
            rig.bench.synthesizer.reportStarted(utterance: 0)
            #expect(await rig.heard("speaking:0"))
            // The clock cuts it: an ENDING, not a failure. The mouth is
            // told first (the event), THEN reports — reported first, its
            // report would complete the turn and the ending would die at
            // the ticket, and `tokensFinished` below would be a coin toss.
            rig.bench.generator.finish(reply: 0, stop: .deadline)
            #expect(await rig.heard("tokensFinished:0"), "the ending reached the mouth as `finishTokens`")
            rig.bench.synthesizer.reportFinished(utterance: 0)
            #expect(await rig.heard("completed:0"), "a deadline completes the turn, like .tokenBudget")

            #expect(await rig.bench.coordinator.currentMemory.map(\.replied) == ["Once upon a time"],
                    "what was said so far is what is remembered")
            await rig.finish()
        }

        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens == ["Once upon", " a time"])
        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true,
                "the mouth was told the sentence is over — the same hand as a .complete")
        let expected: [TurnEvent] = [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("Once upon", turn: 0),
            .replyToken(" a time", turn: 0),
            .stateChanged(.speaking, turn: 0),
            .turnCompleted(turn: 0),
            .stateChanged(.idle, turn: 0)
        ]
        #expect(await rig.bench.box.events == expected, "no event a .tokenBudget ending would not produce")
    }

    /// AC-265's deadline half, on the record: every coordinator-driven
    /// call carries `options.deadline == nil` — the defaults, untouched.
    /// (The policy half is structural, and proven by the test after this
    /// one: the coordinator never constructs the mind, so it has no way
    /// to hand a policy in.)
    @Test("the coordinator passes no deadline: every driven call records deadline == nil (AC-265)")
    func coordinatorPassesNoDeadline() async throws {
        let rig = try await Rig(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "first", at: 0)
            #expect(await rig.heard("thinking:0"))
            await rig.completeManualTurn(0, reply: 0, utterance: 0, tokens: ("One", "."))
            rig.bench.speak(utterance: 1, final: "second", at: 96_000)
            #expect(await rig.heard("thinking:1"))
            await rig.completeManualTurn(1, reply: 1, utterance: 1, tokens: ("Two", "."))
            await rig.finish()
        }

        #expect(rig.bench.generator.repliesOpened == 2)
        for index in 0..<2 {
            let options = rig.bench.generator.record(ofReply: index)?.context.options
            #expect(options?.deadline == nil, "reply \(index): the voice path sets no deadline")
            #expect(options == GenerationOptions(), "reply \(index): the options are the defaults, untouched")
        }
        #expect(rig.bench.generator.heatRefusals.isEmpty,
                "the scripted thermometer the mind defaults to reads .nominal; nothing refused")
    }

    /// AC-265's policy half, proven where it lives: in the coordinator's
    /// SOURCE. The coordinator takes `any ReplyGenerating` and builds its
    /// `ReplyContext` with the default options — it names no thermal
    /// policy, no thermometer, no `GenerationOptions`, so a deadline or a
    /// policy has no seam to travel through. A test that only ran a cool
    /// turn would prove the Mac was cool (the 4y review's objection to
    /// the first draft of this file); reading the source proves the
    /// claim — the way 4x's suspend test proves its own (AC-251).
    @Test("the coordinator's own source names no thermal policy, no thermometer and no GenerationOptions (AC-265)",
          .enabled(if: CoordinatorSource.isReadable,
                   "the MultiModalKit/Conversation sources are not readable from this run"))
    func coordinatorHasNoSeamForAPolicyOrADeadline() throws {
        let sources = try CoordinatorSource.files()
        #expect(sources.count >= 5, "the scan must actually have read the coordinator's files")
        #expect(sources.keys.contains("TurnCoordinator+Transcripts.swift"),
                "the file that opens the reply must be among the ones scanned")
        for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
            // Not the word "deadline" itself: the coordinator has its own
            // (the reply gate's, the barge window's), and those are not
            // the mind's. A deadline can only reach the mind inside
            // `GenerationOptions`, so that name is the needle.
            for needle in ["GenerationThermalPolicy", "ThermalState", "GenerationOptions", "tooHot"] {
                let found = "\(name) names `\(needle)` — the coordinator gained a seam 4y said it "
                    + "must not have (AC-265: no deadline and no policy from the voice path)"
                #expect(!text.contains(needle), Comment(rawValue: found))
            }
        }
    }
}

/// The coordinator's own source, on disk — the `MLXModuleSource` shape,
/// pointed at `Sources/MultiModalKit/Conversation/TurnCoordinator*.swift`.
/// `#filePath` is this file's path at COMPILE time, so four steps up is
/// the package root whenever the tests are built from the package.
private enum CoordinatorSource {
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()    // Conversation
        .deletingLastPathComponent()    // MultiModalKitTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // the package root
        .appending(path: "Sources/MultiModalKit/Conversation")

    static var isReadable: Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    /// Only the coordinator's files: the claim is about the turn loop,
    /// not about the minds that live in the same directory.
    static func files() throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var found: [String: String] = [:]
        for name in names where name.hasPrefix("TurnCoordinator") && name.hasSuffix(".swift") {
            found[name] = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        }
        return found
    }
}
