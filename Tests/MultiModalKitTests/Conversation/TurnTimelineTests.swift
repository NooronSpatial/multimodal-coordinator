// 5d PIECE 1 — THE TURN TIMELINE (SPEC §224–§230; D-132, D-133, D-134).
//
//   you stop ─① hangover─▶ end ─② ear─▶ final ─③ gate─▶ opened ─④ mind─▶ token ─⑤ mouth─▶ FIRST SOUND
//            (the app's policy)                                        reported here (D-133) ┘
//   interrupting: your first sound ─⑦ window─▶ accepted ─⑧ silence─▶ both cancels acknowledged
//
// Every stage is driven by hand on a ManualClock and must come back EXACT.
// The bench (events, not polls) is in `TurnTimelineTests+Rig.swift`.

import MultiModalKit
import MultiModalKitTesting
import Testing

@Suite("AC-335…AC-340 · the turn timeline", .timeLimit(.minutes(1)), .serialized)
struct TurnTimelineTests {

    // MARK: - AC-335, AC-337: one timeline per spoken turn, exact

    @Test("a spoken turn reports every stage, exact, at its first sound (AC-335)")
    func everyStageExact() async throws {
        let rig = try await Rig(config: .init(replyGate: .milliseconds(250)))
        let stages = Stages(earFinish: .milliseconds(80), gate: .milliseconds(250),
                            firstToken: .milliseconds(120), firstSound: .milliseconds(90))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, stages)
            // Reported AT the first sound: the reply is still speaking, and
            // the mouth has not even been told the tokens are over (D-133).
            #expect(await rig.heard("timeline:0"), "the pause must be reported at the first sound")
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines == [
            TurnTimeline(turn: 0, earFinish: .milliseconds(80), gate: .milliseconds(250),
                         firstToken: .milliseconds(120), firstSound: .milliseconds(90))
        ])
    }

    @Test("turnLatency did not move: it is the timeline's stages since the final (AC-337)")
    func turnLatencyDidNotMove() async throws {
        let rig = try await Rig(config: .init(replyGate: .milliseconds(250)))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages(gate: .milliseconds(250)))
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.latencies == [.milliseconds(460)], "250 + 120 + 90, as before 5d")
        #expect(rig.recorder.timelines.map(\.sinceFinal) == rig.recorder.latencies)
    }

    // MARK: - AC-336: the gate is its own stage

    @Test("the gate is its own stage: 500 ms in, 500 ms out (AC-336)")
    func theGateIsItsOwnStage() async throws {
        let rig = try await Rig(config: .init(replyGate: .milliseconds(500)))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages(gate: .milliseconds(500)))
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines.map(\.gate) == [.milliseconds(500)])
    }

    @Test("no gate: the stage is zero, and the others are untouched (AC-336)")
    func noGateIsZero() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages())
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines == [
            TurnTimeline(turn: 0, earFinish: .milliseconds(80), gate: .zero,
                         firstToken: .milliseconds(120), firstSound: .milliseconds(90))
        ])
    }

    // MARK: - ②: the end the coordinator saw, or did not

    @Test("an end the coordinator never saw leaves earFinish empty, not zero")
    func endNeverSeen() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages(), endSeen: false)
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines.map(\.earFinish) == [nil])
        #expect(rig.recorder.timelines.first?.felt(hangover: .milliseconds(300)) == nil)
    }

    @Test("a person who went on: the older utterance's end is not this one's")
    func theOlderEndIsNotThisOne() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            #expect(await rig.heard("listening:0"))
            #expect(await rig.audio.handOver(.speechEnded(at: Self.t(14_400))))
            // They go on before any final: the turn follows utterance 1, whose
            // end the coordinator never sees.
            #expect(await rig.audio.handOver(.speechStarted(utterance: 1, at: Self.t(19_200))))
            await rig.clock.advance(by: .milliseconds(200))
            rig.transcripts.yield(.final("how far is the moon", utterance: 1, at: Self.t(33_600)))
            #expect(await rig.heard("opened:0"))
            rig.generator.emit(reply: 0, token: "Far")
            rig.generator.emit(reply: 0, token: "away.")
            #expect(await rig.heard("token:away.:0"))
            rig.synthesizer.reportStarted(utterance: 0)
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines.map(\.earFinish) == [nil], "utterance 0's end is not utterance 1's")
    }

    @Test("an ear that finishes before the end decision reports a negative earFinish")
    func earBeforeTheEnd() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            #expect(await rig.heard("listening:0"))
            // The ear's own endpointing: the final lands first, and opens the
            // reply; the VAD's decision comes 40 ms later.
            rig.transcripts.yield(.final("how far is the moon", utterance: 0, at: Self.t(14_400)))
            #expect(await rig.heard("opened:0"))
            await rig.clock.advance(by: .milliseconds(40))
            #expect(await rig.audio.handOver(.speechEnded(at: Self.t(14_400))))
            await rig.clock.advance(by: .milliseconds(80))
            rig.generator.emit(reply: 0, token: "Far")
            rig.generator.emit(reply: 0, token: "away.")
            #expect(await rig.heard("token:away.:0"))
            rig.synthesizer.reportStarted(utterance: 0)
            #expect(await rig.heard("timeline:0"))
            await Self.finishTurn(rig)
            await rig.finish()
        }
        #expect(rig.recorder.timelines.map(\.earFinish) == [.milliseconds(-40)])
    }

    // MARK: - AC-338: a barge has its own timeline

    @Test("a barge while speaking: the window, then the silence; the pause was already reported (AC-338)")
    func bargeWhileSpeaking() async throws {
        let rig = try await Rig(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2),
                                config: .init(bargeWindow: .milliseconds(500)),
                                quieting: .milliseconds(70))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages())
            #expect(await rig.heard("timeline:0"))
            // A person over the reply: onset at 2.0 s, still there at 2.25 s,
            // and at 2.5 s the window (500 ms, on the audio timeline) is spent.
            #expect(await rig.audio.handOver(.speechStarted(utterance: 1, at: Self.t(96_000))))
            #expect(await rig.audio.handOver(.audioSegment(AudioChunk(samples: [0], start: Self.t(108_000)))))
            #expect(await rig.audio.handOver(.audioSegment(AudioChunk(samples: [0], start: Self.t(120_000)))))
            #expect(await rig.heard("barged:0"))
            // The mouth takes 70 ms of manual time to go silent.
            #expect(await rig.parked(), "the mouth's cancel must be waiting on the clock")
            await rig.clock.advance(by: .milliseconds(70))
            #expect(await rig.heard("barge:0"))
            await rig.finish()
        }
        #expect(rig.recorder.barges == [BargeTimeline(turn: 0, window: .milliseconds(500),
                                                      silence: .milliseconds(70))])
        #expect(rig.recorder.cancels == [.milliseconds(70)], "the silence is what cancelLatency measured")
        #expect(rig.recorder.timelines.map(\.turn) == [0], "the pause was reported once, at the first sound")
    }

    @Test("a barge with the window off: the window is zero (AC-338)")
    func bargeWithTheWindowOff() async throws {
        let rig = try await Rig(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            await Self.speakToFirstSound(rig, Stages())
            #expect(await rig.audio.handOver(.speechStarted(utterance: 1, at: Self.t(96_000))))
            #expect(await rig.heard("barge:0"))
            await rig.finish()
        }
        #expect(rig.recorder.barges == [BargeTimeline(turn: 0, window: .zero, silence: .zero)])
    }

    @Test("a barge while thinking: no window, and no pause timeline — the turn never spoke (AC-338)")
    func bargeWhileThinking() async throws {
        let rig = try await Rig(generator: .manual(replies: 2), synthesizer: .manual(utterances: 2),
                                config: .init(bargeWindow: .milliseconds(500)))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            rig.transcripts.yield(.final("tell me a story", utterance: 0, at: Self.t(14_400)))
            #expect(await rig.heard("opened:0"))
            #expect(await rig.audio.handOver(.speechStarted(utterance: 1, at: Self.t(96_000))))
            #expect(await rig.heard("barge:0"))
            await rig.finish()
        }
        #expect(rig.recorder.barges == [BargeTimeline(turn: 0, window: .zero, silence: .zero)])
        #expect(rig.recorder.timelines.isEmpty, "cut before its first sound: no pause to report")
    }

    // MARK: - AC-339: a turn that never spoke reports none

    @Test("an empty final reports no timeline (AC-339)")
    func emptyFinal() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            #expect(await rig.audio.handOver(.speechEnded(at: Self.t(14_400))))
            rig.transcripts.yield(.final("  ", utterance: 0, at: Self.t(14_400)))
            #expect(await rig.heard("idle:0"))
            await rig.finish()
        }
        #expect(rig.recorder.timelines.isEmpty)
    }

    @Test("a failed ear reports no timeline (AC-339)")
    func failedEar() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            rig.transcripts.yield(.failed(.engineFailed("mic route died"), utterance: 0, at: Self.t(14_400)))
            #expect(await rig.heard("failed:0"))
            await rig.finish()
        }
        #expect(rig.recorder.timelines.isEmpty)
    }

    @Test("a reply killed inside the gate by a person who goes on reports no timeline (AC-339)")
    func killedInsideTheGate() async throws {
        let rig = try await Rig(config: .init(replyGate: .milliseconds(500)))
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            rig.transcripts.yield(.final("and then", utterance: 0, at: Self.t(14_400)))
            #expect(await rig.parked(), "the gate must be armed")
            // The person goes on: the gated reply dies unspoken (AC-81) …
            #expect(await rig.audio.handOver(.speechStarted(utterance: 1, at: Self.t(24_000))))
            // … and says nothing more, so the turn ends empty.
            rig.transcripts.yield(.final("", utterance: 1, at: Self.t(38_400)))
            #expect(await rig.heard("idle:0"))
            await rig.clock.advance(by: .milliseconds(500))   // the old gate expires into silence
            await rig.finish()
        }
        #expect(rig.recorder.timelines.isEmpty)
        #expect(rig.generator.repliesOpened == 0, "the gated reply never opened")
    }

    @Test("a mind that chose silence reports no timeline (AC-339)")
    func silentMind() async throws {
        let rig = try await Rig()
        await withTaskGroup(of: Void.self) { group in
            rig.start(in: &group)
            #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: Self.t(0))))
            rig.transcripts.yield(.final("hm", utterance: 0, at: Self.t(14_400)))
            #expect(await rig.heard("opened:0"))
            rig.generator.finish(reply: 0)
            #expect(await rig.heard("completed:0"))
            await rig.finish()
        }
        #expect(rig.recorder.timelines.isEmpty)
    }

    // MARK: - AC-340: nothing breaks; the felt pause

    /// A reporter written for 0.5.0: the two old requirements, nothing more.
    struct ReporterFrom050: LatencyReporter {
        func turnLatency(_ duration: Duration, turn: Int) {}
        func cancelLatency(_ duration: Duration, turn: Int) {}
    }

    @Test("a reporter written for 0.5.0 still conforms, and the new hand-offs default to nothing (AC-340)")
    func oldReportersStillConform() throws {
        let reporter: any LatencyReporter = ReporterFrom050()
        reporter.turnTimeline(TurnTimeline(turn: 0, earFinish: nil, gate: .zero,
                                           firstToken: .zero, firstSound: .zero))
        reporter.bargeTimeline(BargeTimeline(turn: 0, window: .zero, silence: .zero))
        _ = try TurnCoordinator(replyGenerator: ScriptedReplyGenerator.manual(replies: 1),
                                synthesizer: ScriptedSynthesizer.manual(utterances: 1),
                                clock: ManualClock(), latencyReporter: ReporterFrom050())
    }

    @Test("the felt pause is the app's hangover plus every stage")
    func feltPause() {
        let timeline = TurnTimeline(turn: 3, earFinish: .milliseconds(80), gate: .milliseconds(500),
                                    firstToken: .milliseconds(120), firstSound: .milliseconds(90))
        #expect(timeline.sinceFinal == .milliseconds(710))
        #expect(timeline.felt(hangover: .milliseconds(300)) == .milliseconds(1_090))
    }
}
