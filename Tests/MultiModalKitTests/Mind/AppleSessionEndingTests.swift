// 5b piece 3a: WHEN A SESSION ENDS (AC-306 through the coordinator,
// AC-307, AC-310; D-117 F-9 A and F-10 A, D-118 F-13 A).
//
//     a barge, a deadline ─▶ the answer did not finish ─┐
//     the answer failed ───────────────────────────────┤─▶ the session is let go,
//     stop(), clearMemory() ─▶ endConversation() ──────┘   and the next turn is
//                                                          SEEDED from the memory
//     every seeding ─▶ HealthEvent.mindSessionSeeded(reason, turns:)
//
// Every row drives `FakeSessionMaker`; the health road is read the way an
// app reads it (`HealthLog`).

import Synchronization
import Testing
@testable import MultiModalKit

/// The health road, read the way an app reads it: every event kept, and
/// each session's birth also an EVENT a row can wait for. `close()`
/// returns once every published event has been read.
final class HealthLog: Sendable {
    let diagnostics = PipelineDiagnostics(thermal: StillThermometer())
    let signals = ToolSpikeTests.Signals()
    private let seen = Mutex<[HealthEvent]>([])
    private let reading = Mutex<Task<Void, Never>?>(nil)

    init() {
        let listener = diagnostics.health()
        let task = Task { [weak self] in
            for await event in listener.events {
                guard let self else { return }
                self.seen.withLock { $0.append(event) }
                if case .mindSessionSeeded(let reason, let turns) = event {
                    self.signals.send("seeded:\(reason):\(turns)")
                }
            }
        }
        reading.withLock { $0 = task }
    }

    /// Every session birth heard, in order.
    var seeds: [HealthEvent] {
        seen.withLock { $0.filter { if case .mindSessionSeeded = $0 { true } else { false } } }
    }

    /// Closes the road and waits until everything published was read.
    func close() async {
        diagnostics.stop()
        await reading.withLock { $0 }?.value
    }
}

@Suite("AC-306/307/310 · when a session ends", .timeLimit(.minutes(1)), .serialized)
struct AppleSessionEndingTests {

    // MARK: - AC-307: a failure re-seeds, and says so

    @Test("a failure re-seeds the next turn from the memory, and the trace says why (AC-307)")
    func aFailureReseedsAndSaysWhy() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker { prompt in
            prompt == "question 2" ? .fails("the model fell over") : .answers(["Answer to \(prompt)."])
        }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        var talk = AppleSessionTests.Talk()
        try await talk.turn("question 1", with: generator)
        do {
            try await talk.turn("question 2", with: generator)
            Issue.record("the failing answer should have thrown")
        } catch {}
        let before = talk.memory.turns
        try await talk.turn("question 3", with: generator)
        await log.close()

        #expect(maker.made.count == 2, "turn three was served by a NEW session")
        #expect(maker.made.last?.seed == before, "seeded from the memory — the failed turn is not in it")
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.lastAnswerFailed("the model fell over"), turns: 1)])
    }

    @Test("a failed session is let go at once, before the next turn exists (AC-307)")
    func aFailedSessionIsReleasedAtOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let maker = FakeSessionMaker { _ in .fails("the model fell over") }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer())
        let keeper = try #require(generator.source as? SessionKeeper)
        do {
            _ = try await generator.reply(to: ReplyContext(transcript: "question 1"))
            Issue.record("the failing answer should have thrown")
        } catch {}
        #expect(!keeper.holdsSession, "nothing kept for a session that failed")
    }

    @Test("an answer the memory will not keep lets the session go, and the trace says why")
    func anUnkeptAnswerLetsTheSessionGo() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker { prompt in
            prompt == "question 1" ? .answers([" "]) : .answers(["Answer to \(prompt)."])
        }
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        let keeper = try #require(generator.source as? SessionKeeper)
        var talk = AppleSessionTests.Talk()
        try await talk.turn("question 1", with: generator)
        #expect(!keeper.holdsSession, "the session holds a turn the memory refused: they can never agree")
        try await talk.turn("question 2", with: generator)
        await log.close()
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.memoryChanged, turns: 0)])
    }

    // MARK: - AC-306, through the coordinator

    /// The first answer says "Let me" and holds; the next onset barges it
    /// (no barge window: an onset while speaking IS a barge). The memory
    /// keeps the cut turn, marked interrupted — and that is what the next
    /// session is born holding.
    @Test("a barge re-seeds the next turn from the memory, the cut turn marked interrupted (AC-306)")
    func aBargeReseedsWithTheCutTurnMarked() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker { prompt in
            prompt == "question 0" ? .snapshotThenHold("Let me") : .answers(["Answer to \(prompt)."])
        }
        let rig = try await CoordinatorRig(
            mind: try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                          diagnostics: log.diagnostics))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            rig.begin("question 0", utterance: 0)
            #expect(await rig.signals.heard("speaking:0"), "the cut answer's first words are being spoken")
            rig.onset(utterance: 1)
            #expect(await rig.signals.heard("barged:0"))
            rig.final("question 1", utterance: 1)
            #expect(await rig.signals.heard("completed:1"))
            await rig.end()
        }
        await log.close()

        #expect(maker.made.count == 2)
        #expect(maker.made.last?.seed == [ConversationTurn(said: "question 0", replied: "Let me",
                                                           interrupted: true)],
                "the cut turn, marked — never a completed response")
        #expect(maker.sessions.first?.asked.map(\.prompt) == ["question 0"],
                "the cut session answered nothing more")
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.lastAnswerUnfinished, turns: 1)])
    }

    // MARK: - AC-310: the conversation's end

    @Test("stop() lets the conversation's session go (AC-310)")
    func stopReleasesTheSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let generator = try AppleReplyGenerator(sessions: FakeSessionMaker(), thermal: StillThermometer())
        let keeper = try #require(generator.source as? SessionKeeper)
        let rig = try await CoordinatorRig(mind: generator)
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.say("question 0", utterance: 0))
            #expect(keeper.holdsSession, "the conversation's session, kept between turns")
            await rig.end()
        }
        #expect(!keeper.holdsSession, "after stop(), no session is held")
    }

    @Test("a new conversation on the same generator starts a new session, from no past (AC-310)")
    func aNewConversationStartsANewSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        for conversation in 0..<2 {
            let rig = try await CoordinatorRig(mind: generator)
            await withTaskGroup(of: Void.self) { group in
                rig.start(in: &group)
                #expect(await rig.say("hello \(conversation)", utterance: 0))
                await rig.end()
            }
        }
        await log.close()
        #expect(maker.made.map(\.seed) == [[], []], "each conversation began with no past")
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.newConversation, turns: 0)])
    }

    @Test("clearMemory() ends the conversation's session too (AC-310)")
    func clearMemoryReleasesTheSession() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let maker = FakeSessionMaker()
        let generator = try AppleReplyGenerator(sessions: maker, thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        let keeper = try #require(generator.source as? SessionKeeper)
        let rig = try await CoordinatorRig(mind: generator)
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.say("question 0", utterance: 0))
            await rig.coordinator.clearMemory()
            #expect(!keeper.holdsSession, "forgetting the past lets its session go")
            #expect(await rig.say("question 1", utterance: 1))
            await rig.end()
        }
        await log.close()
        #expect(maker.made.map(\.seed) == [[], []])
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0),
                              .mindSessionSeeded(.newConversation, turns: 0)])
    }

    // MARK: - what the trace does NOT say

    @Test("a continued turn reports nothing: only a session's birth is reported (D-118 F-13 A)")
    func onlyBirthsAreReported() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let generator = try AppleReplyGenerator(sessions: FakeSessionMaker(), thermal: StillThermometer(),
                                                diagnostics: log.diagnostics)
        var talk = AppleSessionTests.Talk()
        try await talk.turns(3, with: generator)
        await log.close()
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0)])
    }

    @Test("a session made aside is not the conversation's, and is not reported (AC-309, D-118)")
    func anAsideIsNotReported() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let log = HealthLog()
        let generator = try AppleReplyGenerator(instructions: "speak briefly", sessions: FakeSessionMaker(),
                                                thermal: StillThermometer(), diagnostics: log.diagnostics)
        var talk = AppleSessionTests.Talk()
        try await talk.turn("question 1", with: generator)
        _ = try await generator.reply(to: ReplyContext(
            transcript: "summarise today", history: talk.memory.turns,
            options: MultiModalKit.GenerationOptions(instructions: "reply as JSON")))
        try await talk.turn("question 2", with: generator)
        await log.close()
        #expect(log.seeds == [.mindSessionSeeded(.newConversation, turns: 0)])
    }
}
