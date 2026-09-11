// THE TOOL SPIKE'S TESTS (4w, SPEC §169/3, §171, §172c; D-101).
//
// F-1 = B is the ruling under test: the run executes the tool ITSELF and
// the seam does not change. So none of these tests teaches the
// coordinator anything — they put a scripted mind that CALLS a scripted
// tool behind the seam the coordinator already has. This file holds the
// bench and AC-221; `ToolSpikeTests+Survival.swift` holds the three the
// brief named — a slow tool (AC-224), a failing tool (AC-225), and a
// barge while the call is in flight (AC-226).
//
// **Nothing here polls** (§3.3, and the 4t runner freeze). Every wait is
// an EVENT: the coordinator's own stream is forwarded into `Signals`, the
// scripted tool signals the moment it is entered, and the scripted run
// signals when it has pushed its last update. Each wait races a SLEEPING
// deadline, so a red test still dies in ten seconds. `.serialized` for
// the same reason the runtime tests are: nothing overlaps until the
// runner's freeze is explained.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct ToolSpikeTests {
    typealias Bench = TurnCoordinatorTests.Bench<ManualClock>

    /// The EVENT a test waits on. Like the runtime tests' `Signals`, with
    /// one addition: names already heard are remembered, so two waits in
    /// a row ("entered", then "barged:0") cannot lose the one that arrived
    /// while the other was being awaited — an `AsyncStream` has one
    /// consumer and no rewind.
    final class Signals: Sendable {
        private let seen = Mutex<[String]>([])
        private let stream: AsyncStream<String>
        private let emit: AsyncStream<String>.Continuation

        init() {
            (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        }

        func send(_ name: String) {
            seen.withLock { $0.append(name) }
            emit.yield(name)
        }

        /// True when `name` has arrived, or arrives before the deadline.
        /// The loser of the race is cancelled, never abandoned.
        func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
            if seen.withLock({ $0.contains(name) }) { return true }
            return await withTaskGroup(of: Bool.self) { group in
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

    /// The coordinator's events as names a test can wait for.
    static func name(of event: TurnEvent) -> String {
        switch event {
        case .stateChanged(let state, let turn): "\(state):\(turn)"
        case .replyToken(let token, let turn): "token:\(token):\(turn)"
        case .turnCompleted(let turn): "completed:\(turn)"
        case .turnBarged(let turn): "barged:\(turn)"
        case .turnFailed(_, let turn): "failed:\(turn)"
        }
    }

    /// The measuring bench (a `ManualClock`, AC-224's requirement), plus
    /// the signals the coordinator's events become and the reporter that
    /// measures the barge's cancel.
    struct Rig {
        let bench: Bench
        let signals = Signals()
        let reporter = TurnCoordinatorTests.RecordingLatencyReporter()
        private let listener: Broadcast<TurnEvent>.Listener
        private let forwarded: Broadcast<TurnEvent>.Listener

        init(generator: ScriptedReplyGenerator, synthesizer: ScriptedSynthesizer) async throws {
            bench = try Bench(generator: generator, synthesizer: synthesizer,
                              clock: ManualClock(), reporter: reporter)
            listener = await bench.coordinator.listen()
            forwarded = await bench.coordinator.listen()
        }

        /// The loop, the collector, and the forwarder — all in the group.
        func start(in group: inout TaskGroup<Void>) {
            bench.start(in: &group, listener: listener)
            let signals = signals
            let forwarded = forwarded
            group.addTask {
                for await event in forwarded.events { signals.send(ToolSpikeTests.name(of: event)) }
            }
        }

        func heard(_ name: String) async -> Bool { await signals.heard(name) }

        /// Drives a `.manual` reply to a completed turn: two tokens (the
        /// second's event proves the mouth opened on the first — the mouth
        /// opens AFTER a token is published, so one token's event alone
        /// would not), the mouth's evidence, the finish.
        func completeManualTurn(_ turn: Int, reply: Int, utterance: Int,
                                tokens: (String, String)) async {
            bench.generator.emit(reply: reply, token: tokens.0)
            bench.generator.emit(reply: reply, token: tokens.1)
            #expect(await heard("token:\(tokens.1):\(turn)"))
            bench.synthesizer.reportStarted(utterance: utterance)
            #expect(await heard("speaking:\(turn)"))
            bench.generator.finish(reply: reply)
            bench.synthesizer.reportFinished(utterance: utterance)
            #expect(await heard("completed:\(turn)"))
        }

        /// A barge while reply 0 is inside its tool call: the onset, the
        /// barge event, the new final, and the new reply opening — which
        /// is the fact that the barge's cancels have RETURNED, so reply 0
        /// has been told by then.
        func bargeDuringTheCall() async {
            bench.audio.yield(.speechStarted(utterance: 1, at: TurnCoordinatorTests.t(48_000)))
            #expect(await heard("barged:0"), "the coordinator must answer while the tool is pending")
            #expect(await heard("listening:1"))
            bench.transcripts.yield(.final("never mind", utterance: 1, at: TurnCoordinatorTests.t(49_000)))
            #expect(await heard("thinking:1"))
            #expect(bench.generator.record(ofReply: 0)?.cancelled == true, "reply 0 was told")
        }

        func finish() async {
            bench.finishInputs()
            await bench.coordinator.stop()
        }
    }

    /// The throwaway tool's stub answer (F-3 = C): a fixed session with a
    /// readiness verdict, owned by whoever plays the app.
    static let session = "Push day: 40 minutes of intervals, readiness green."

    /// What every barged-during-the-call run must leave behind: the exact
    /// stream, with nothing of turn 0 after its barge (AC-63's shape).
    static let bargedSequence: [TurnEvent] = [
        .stateChanged(.listening, turn: 0),
        .stateChanged(.thinking, turn: 0),
        .turnBarged(turn: 0),
        .stateChanged(.listening, turn: 1),
        .stateChanged(.thinking, turn: 1),
        .replyToken("OK", turn: 1),
        .replyToken(".", turn: 1),
        .stateChanged(.speaking, turn: 1),
        .turnCompleted(turn: 1),
        .stateChanged(.idle, turn: 1)
    ]

    // MARK: - AC-221 under F-1 = B

    /// **THE SEAM LEARNED NOTHING.** A reply that calls a tool looks, from
    /// the coordinator's side, exactly like one that did not: tokens, one
    /// terminal, the usual events. The proof of the call is on the OTHER
    /// side of the seam — the tool's own record of its arguments, and the
    /// run's record of the outcome — and the proof of the answer is in the
    /// tokens that follow it.
    @Test("AC-221: the run calls the tool itself — the coordinator sees only tokens and one terminal")
    func theRunCallsTheToolItself() async throws {
        let tool = ScriptedTool(name: "session", plan: .answers(Self.session))
        let script = ToolScript(name: "session", arguments: ["day": "today"],
                                before: ["Let me check. "], after: [" Ready?"])
        let rig = try await Rig(
            generator: ScriptedReplyGenerator(plans: [.callsTool(script)], tools: ToolTable([tool.tool])),
            synthesizer: .manual(utterances: 1))

        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)

            rig.bench.speak(utterance: 0, final: "what is today's session", at: 0)
            // The LAST token is the fact that everything before it — the
            // call, the answer — went through, and that the mouth opened.
            #expect(await rig.heard("token: Ready?:0"), "the answer must be followed by the script's tail")
            rig.bench.synthesizer.reportStarted(utterance: 0)
            #expect(await rig.heard("speaking:0"))
            rig.bench.synthesizer.reportFinished(utterance: 0)
            #expect(await rig.heard("completed:0"))

            #expect(await rig.bench.coordinator.currentMemory.map(\.replied)
                    == ["Let me check. \(Self.session) Ready?"],
                    "the answer is part of the reply the conversation remembers")
            await rig.finish()
        }

        // The call, with the arguments the script gave (AC-221).
        #expect(tool.calls == [["day": "today"]])
        #expect(rig.bench.generator.record(ofReply: 0)?.toolCalls == [
            ToolCallRecord(name: "session", arguments: ["day": "today"],
                           outcome: .answered(Self.session))
        ])
        // The mouth heard the answer as an ordinary token.
        #expect(rig.bench.synthesizer.record(ofUtterance: 0)?.fedTokens
                == ["Let me check. ", Self.session, " Ready?"])
        // And the coordinator's stream: the EXACT sequence, nothing new in it.
        let expected: [TurnEvent] = [
            .stateChanged(.listening, turn: 0),
            .stateChanged(.thinking, turn: 0),
            .replyToken("Let me check. ", turn: 0),
            .replyToken(Self.session, turn: 0),
            .replyToken(" Ready?", turn: 0),
            .stateChanged(.speaking, turn: 0),
            .turnCompleted(turn: 0),
            .stateChanged(.idle, turn: 0)
        ]
        #expect(await rig.bench.box.events == expected)
    }

    /// THE COMPILER IS THE ASSERTION (the `ReplyContractTests` pattern):
    /// F-1 = B promised `ReplyUpdate` would not grow a case for tools.
    /// Add one and, under warnings-as-errors, this switch stops compiling.
    @Test("F-1 = B: ReplyUpdate is still .token / .finished / .failed")
    func replyUpdateLearnedNothing() {
        let every: [ReplyUpdate] = [.token("t"), .finished(.complete), .failed(.busy)]
        for update in every {
            switch update {
            case .token, .finished, .failed:
                break
            }
        }
        #expect(every.map(String.init(describing:)).count == every.count)
    }

    // MARK: - the table's one lookup rule

    @Test("ToolTable: exact name, nil for a stranger, both failures typed")
    func toolTableLookupRule() async {
        let tool = ScriptedTool(name: "session", plan: .answers("green"))
        let broken = ScriptedTool(name: "broken", plan: .throwsError("no"))
        let table = ToolTable([tool.tool, broken.tool])

        #expect(table["session"]?.name == "session")
        #expect(table["Session"] == nil, "case-sensitive: one rule, no guessing")
        #expect(table["weather"] == nil)
        #expect(ToolTable.empty.isEmpty)

        let answered = await table.call("session", arguments: ["a": "1"])
        #expect(answered == .success("green"))
        #expect(tool.calls == [["a": "1"]])
        let unknown = await table.call("weather", arguments: [:])
        #expect(unknown == .failure(ToolCallFailure(tool: "weather", reason: .unknownTool)))
        let threw = await table.call("broken", arguments: [:])
        #expect(threw == .failure(ToolCallFailure(tool: "broken", reason: .threw("no"))))
        #expect(ToolCallFailure(tool: "broken", reason: .threw("no")).description
                == "tool 'broken' failed: no")
        #expect(ToolCallFailure(tool: "weather", reason: .unknownTool).description
                == "no tool named 'weather'")
    }
}
