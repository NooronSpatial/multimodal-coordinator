// 5d PIECE 4 — THINK IN THE GATE (SPEC §250–§255, D-144).
//
//   the final ─▶ the mind opened AT ONCE ─▶ its words HELD (no token event, no mouth, no memory)
//                 ├─ the gate runs out  ─▶ thinking, then the held words, in order, once
//                 └─ the person goes on ─▶ thrown away in silence; the reply ticket stops its stragglers
//
// On a ManualClock: the gate's end is an `advance`, so every instant is exact.
// "Held" is a fact the coordinator states (`heldReplyUpdates`, internal), so a
// row waits for it instead of hoping the words arrived before the gate ran out.

@testable import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

/// Everything the coordinator measured, as it was handed over.
final class EarlyRecorder: LatencyReporter, Sendable {
    private struct Kept {
        var early: [EarlyReply] = []
        var timelines: [TurnTimeline] = []
        var latencies: [Duration] = []
    }
    private let kept = Mutex(Kept())

    func turnLatency(_ duration: Duration, turn: Int) { kept.withLock { $0.latencies.append(duration) } }
    func cancelLatency(_ duration: Duration, turn: Int) {}
    func turnTimeline(_ timeline: TurnTimeline) { kept.withLock { $0.timelines.append(timeline) } }
    func earlyReply(_ report: EarlyReply) { kept.withLock { $0.early.append(report) } }

    var early: [EarlyReply] { kept.withLock { $0.early } }
    var timelines: [TurnTimeline] { kept.withLock { $0.timelines } }
    var latencies: [Duration] { kept.withLock { $0.latencies } }
}

@Suite("AC-363…AC-370 · think in the gate", .timeLimit(.minutes(1)))
struct ThinkInTheGateTests {

    typealias Bench = TurnCoordinatorTests.Bench<ManualClock>

    static func bench(_ generator: ScriptedReplyGenerator, utterances: Int = 1, clock: ManualClock,
                      recorder: EarlyRecorder, thinks: Bool = true,
                      gate: Duration = .milliseconds(500)) throws -> Bench {
        try Bench(generator: generator, synthesizer: .manual(utterances: utterances),
                  clock: clock, reporter: recorder,
                  config: .init(replyGate: gate, thinksInTheGate: thinks))
    }

    static func t(_ frames: Int) -> AudioTime { TurnCoordinatorTests.t(frames) }

    /// The tokens the app was shown, in order.
    static func tokens(_ events: [TurnEvent]) -> [String] {
        events.compactMap { if case .replyToken(let token, _) = $0 { token } else { nil } }
    }

    /// Whether `.thinking` came before every token and failure the app saw:
    /// nothing of the reply left the coordinator while it was still listening.
    static func heldUntilThinking(_ events: [TurnEvent], turn: Int) -> Bool {
        guard let thinking = events.firstIndex(of: .stateChanged(.thinking, turn: turn)) else { return false }
        return !events[..<thinking].contains { event in
            switch event {
            case .replyToken, .turnFailed: true
            default: false
            }
        }
    }

    /// Speaks the reply the mouth was opened with, to the end of the turn.
    static func speakToTheEnd(_ bench: Bench, utterance: Int, turn: Int) async {
        let finished = await TurnCoordinatorTests.until {
            bench.synthesizer.record(ofUtterance: utterance)?.tokensFinished == true
        }
        #expect(finished, "the mouth was never told the words were over")
        bench.synthesizer.reportStarted(utterance: utterance)
        bench.synthesizer.reportFinished(utterance: utterance)
        let completed = await TurnCoordinatorTests.until {
            await bench.box.events.contains(.turnCompleted(turn: turn))
        }
        #expect(completed, "the turn never completed")
    }

    // MARK: - AC-363, AC-364: opened at the final, held, released at the gate's end

    @Test("the mind opens at the final; its words are held until the gate runs out, then go on in order, once")
    func openedAtTheFinalAndHeld() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(.manual(replies: 1), clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "the capital of Germany?", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed, "no gate armed")
            let openedEarly = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(openedEarly, "the mind was not opened at the final")

            bench.generator.emit(reply: 0, token: "Ber")
            bench.generator.emit(reply: 0, token: "lin.")
            bench.generator.finish(reply: 0)
            let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 3 }
            #expect(held, "two tokens and the terminal must be HELD while the gate runs")
            #expect(bench.synthesizer.utterancesOpened == 0, "the mouth opened inside the gate")
            #expect(await bench.coordinator.currentState == .listening)

            await clock.advance(by: .milliseconds(500))
            let mouth = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            #expect(mouth, "the gate ran out and the mouth never opened")
            await Self.speakToTheEnd(bench, utterance: 0, turn: 0)
            #expect(bench.synthesizer.record(ofUtterance: 0)?.fedTokens.joined() == "Berlin.",
                    "the held words reach the mouth whole, in order")
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        let events = await bench.box.events
        #expect(Self.heldUntilThinking(events, turn: 0), "a word left the coordinator while it listened")
        #expect(Self.tokens(events) == ["Ber", "lin."], "each held word, exactly once")
        #expect(recorder.early == [EarlyReply(turn: 0, kept: true, thought: .milliseconds(500))])
    }

    // MARK: - AC-365: the person goes on

    @Test("the person goes on: the early reply is thrown away in silence, stragglers too; next, the whole thought")
    func thePersonGoesOn() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        // Reply 0 is DEFIANT: it ignores its cancel and keeps its stream open,
        // so the stragglers forced below really reach the coordinator. (The
        // first green run used a conformant reply here: its stream closed at
        // the cancel, the stragglers never arrived, and the row waited for
        // drops that could not happen — the test's mistake, not the code's.)
        let generator = ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true), .manual(), .manual()])
        let bench = try Self.bench(generator, utterances: 2, clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "the user was not done", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            let openedEarly = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(openedEarly)
            bench.generator.emit(reply: 0, token: "Sure")
            let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 1 }
            #expect(held)

            await clock.advance(by: .milliseconds(200))
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
            let cancelled = await TurnCoordinatorTests.until { bench.generator.record(ofReply: 0)?.cancelled == true }
            #expect(cancelled, "the onset must cancel the early reply")
            #expect(await bench.coordinator.heldReplyUpdates == 0, "its held words go with it")

            // A defiant mind: words and a terminal AFTER the cancel.
            bench.generator.forceToken(reply: 0, token: "ghost")
            bench.generator.forceFinished(reply: 0)
            let dropped = await TurnCoordinatorTests.until { await bench.coordinator.staleReplyUpdatesDropped == 2 }
            #expect(dropped, "the reply ticket must stop both stragglers")

            bench.transcripts.yield(.final("now I am done", utterance: 1, at: Self.t(96_000)))
            let reopened = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 2 }
            #expect(reopened, "the next final opens a new early reply")
            #expect(bench.generator.record(ofReply: 1)?.transcript == "the user was not done now I am done",
                    "the whole thought (AC-88)")
            bench.generator.emit(reply: 1, token: "Okay.")
            bench.generator.finish(reply: 1)
            let heldAgain = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 2 }
            #expect(heldAgain)
            await clock.advance(by: .milliseconds(500))
            await Self.speakToTheEnd(bench, utterance: 0, turn: 0)

            // The next turn's mind is shown what was SAID — not the thrown-away words.
            bench.speak(utterance: 2, final: "and then?", at: 144_000)
            let third = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 3 }
            #expect(third)
            #expect(bench.generator.record(ofReply: 2)?.history.map(\.replied) == ["Okay."],
                    "the memory holds the spoken reply only")
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        let events = await bench.box.events
        #expect(Self.tokens(events) == ["Okay."], "no thrown-away word ever reached the app")
        #expect(recorder.early.prefix(2) == [EarlyReply(turn: 0, kept: false, thought: .milliseconds(200)),
                                             EarlyReply(turn: 0, kept: true, thought: .milliseconds(500))])
    }
}

// The rest of the suite: failures, tools, the switch, the timeline, who may act.
extension ThinkInTheGateTests {

    // MARK: - AC-366: a failure in the gate

    @Test("a reply that fails in the gate fails the turn only when the gate runs out")
    func aFailureIsHeld() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(.manual(replies: 1), clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "fail, please", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            let openedEarly = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(openedEarly)
            bench.generator.fail(reply: 0, reason: "no brain today")
            let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 1 }
            #expect(held, "the failure must be held while the gate runs")
            await clock.advance(by: .milliseconds(500))
            let failed = await TurnCoordinatorTests.until {
                await bench.box.events.contains { if case .turnFailed(_, turn: 0) = $0 { true } else { false } }
            }
            #expect(failed, "the gate ran out and the held failure never failed the turn")
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        #expect(Self.heldUntilThinking(await bench.box.events, turn: 0), "the failure left before the gate ran out")
    }

    @Test("a mind that cannot even open, inside the gate, fails the turn only when the gate runs out")
    func anOpenFailureIsHeld() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(ScriptedReplyGenerator(plans: [.failOnOpen("no brain today")]),
                                   clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "fail at the door", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 1 }
            #expect(held, "the open's failure must be held while the gate runs")
            await clock.advance(by: .milliseconds(500))
            let failed = await TurnCoordinatorTests.until {
                await bench.box.events.contains { if case .turnFailed(_, turn: 0) = $0 { true } else { false } }
            }
            #expect(failed)
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        #expect(Self.heldUntilThinking(await bench.box.events, turn: 0))
    }

    @Test("a failure in the gate disappears with its reply when the person goes on")
    func aFailureGoesWithItsReply() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(.manual(replies: 2), clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "wait", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            let openedEarly = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(openedEarly)
            bench.generator.fail(reply: 0, reason: "no brain today")
            let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 1 }
            #expect(held)
            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(48_000)))
            let gone = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 0 }
            #expect(gone)
            bench.transcripts.yield(.final("I mean, hello", utterance: 1, at: Self.t(96_000)))
            let reopened = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 2 }
            #expect(reopened)
            bench.generator.emit(reply: 1, token: "Hello!")
            bench.generator.finish(reply: 1)
            await clock.advance(by: .milliseconds(500))
            await Self.speakToTheEnd(bench, utterance: 0, turn: 0)
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        let events = await bench.box.events
        #expect(!events.contains { if case .turnFailed = $0 { true } else { false } },
                "a thrown-away reply's failure is no one's")
    }

    // MARK: - AC-369, AC-370: never early with tools; off means today

    static let aTool = ScriptedTool(name: "log_meal", plan: .answers("logged"))

    @Test("a mind that may act — it has tools — is opened when the gate runs out, as today")
    func toolsAreNeverEarly() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let generator = ScriptedReplyGenerator(plans: [.manual()], tools: ToolTable([Self.aTool.tool]))
        #expect(generator.mayActDuringReply, "a mind with tools may act")
        let bench = try Self.bench(generator, clock: clock, recorder: recorder)
        try await Self.gateOpensAsToday(bench, clock: clock)
        #expect(recorder.early.isEmpty, "a mind that may act was opened inside the gate")
        #expect(recorder.timelines.map(\.thoughtInTheGate) == [.zero])
    }

    @Test("off means today: the opt-in off, the mind opens when the gate runs out")
    func offMeansToday() async throws {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(.manual(replies: 1), clock: clock, recorder: recorder, thinks: false)
        try await Self.gateOpensAsToday(bench, clock: clock)
        #expect(recorder.early.isEmpty)
        #expect(recorder.timelines.map(\.thoughtInTheGate) == [.zero])
    }

    /// One turn the old way: the gate runs out, THEN the mind opens; spoken
    /// to its first sound so the timeline is reported.
    static func gateOpensAsToday(_ bench: Bench, clock: ManualClock) async throws {
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "log my lunch", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            await clock.advance(by: .milliseconds(500))
            let opened = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(opened)
            bench.generator.emit(reply: 0, token: "Done.")
            bench.generator.finish(reply: 0)
            let mouth = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            #expect(mouth)
            await Self.speakToTheEnd(bench, utterance: 0, turn: 0)
            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    // MARK: - AC-367: the timeline under overlap

    @Test("held at the gate's end: ③ is the gate, ④ is zero, and the thinking inside the gate is reported")
    func theTimelineWithAHeldToken() async throws {
        let timeline = try await Self.timeline(tokenAt: .milliseconds(200))
        #expect(timeline.timelines == [TurnTimeline(
            turn: 0, earFinish: nil, gate: .milliseconds(500), firstToken: .zero,
            firstSound: .milliseconds(200), thoughtInTheGate: .milliseconds(500))])
        #expect(timeline.latencies == [.milliseconds(700)], "③ + ④ + ⑤ is still the felt pause (AC-337)")
    }

    @Test("a first token after the gate's end: ④ is what was left to wait for it")
    func theTimelineWithALateToken() async throws {
        let timeline = try await Self.timeline(tokenAt: .milliseconds(800))
        #expect(timeline.timelines == [TurnTimeline(
            turn: 0, earFinish: nil, gate: .milliseconds(500), firstToken: .milliseconds(300),
            firstSound: .milliseconds(200), thoughtInTheGate: .milliseconds(500))])
        #expect(timeline.latencies == [.milliseconds(1_000)])
    }

    /// One early turn on the manual clock: the first token at `tokenAt` after
    /// the final, the first sound 200 ms after the token reached the mouth.
    static func timeline(tokenAt: Duration) async throws -> EarlyRecorder {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try Self.bench(.manual(replies: 1), clock: clock, recorder: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "time me", at: 0)
            let armed = await TurnCoordinatorTests.parked(clock)
            #expect(armed)
            let openedEarly = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(openedEarly)
            if tokenAt < .milliseconds(500) {
                await clock.advance(by: tokenAt)
                bench.generator.emit(reply: 0, token: "Hi.")
                let held = await TurnCoordinatorTests.until { await bench.coordinator.heldReplyUpdates == 1 }
                #expect(held)
                await clock.advance(by: .milliseconds(500) - tokenAt)
            } else {
                await clock.advance(by: .milliseconds(500))
                let thinking = await TurnCoordinatorTests.until { await bench.coordinator.currentState == .thinking }
                #expect(thinking)
                await clock.advance(by: tokenAt - .milliseconds(500))
                bench.generator.emit(reply: 0, token: "Hi.")
            }
            let mouth = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            #expect(mouth)
            await clock.advance(by: .milliseconds(200))
            bench.synthesizer.reportStarted(utterance: 0)
            let reported = await TurnCoordinatorTests.until { !recorder.timelines.isEmpty }
            #expect(reported)
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        return recorder
    }

    // MARK: - F-47: who may act

    @Test("the scripted mind may act exactly when it has tools")
    func theScriptedMindSays() {
        #expect(!ScriptedReplyGenerator.manual(replies: 1).mayActDuringReply)
        #expect(ScriptedReplyGenerator(plans: [], tools: ToolTable([Self.aTool.tool])).mayActDuringReply)
    }
}
