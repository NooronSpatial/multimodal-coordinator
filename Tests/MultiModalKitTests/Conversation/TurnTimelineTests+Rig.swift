// `TurnTimelineTests`, continued: the bench. Nothing here polls — every
// wait is an EVENT (the recorder's hand-offs, the coordinator's stream as
// names, the audio reader's pulls, the clock's sleepers), each raced
// against a sleeping cap so a red test dies in seconds, never hangs.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

extension TurnTimelineTests {

    typealias Signals = ToolSpikeTests.Signals

    static func t(_ frames: Int) -> AudioTime { TurnCoordinatorTests.t(frames) }

    // MARK: - the recorder: every hand-off, kept and announced

    final class Recorder: LatencyReporter, Sendable {
        struct Kept: Sendable {
            var timelines: [TurnTimeline] = []
            var barges: [BargeTimeline] = []
            var latencies: [Duration] = []
            var cancels: [Duration] = []
        }
        private let kept = Mutex(Kept())
        private let signals: Signals

        init(signals: Signals) { self.signals = signals }

        var timelines: [TurnTimeline] { kept.withLock { $0.timelines } }
        var barges: [BargeTimeline] { kept.withLock { $0.barges } }
        var latencies: [Duration] { kept.withLock { $0.latencies } }
        var cancels: [Duration] { kept.withLock { $0.cancels } }

        func turnLatency(_ duration: Duration, turn: Int) {
            kept.withLock { $0.latencies.append(duration) }
        }
        func cancelLatency(_ duration: Duration, turn: Int) {
            kept.withLock { $0.cancels.append(duration) }
        }
        func turnTimeline(_ timeline: TurnTimeline) {
            kept.withLock { $0.timelines.append(timeline) }
            signals.send("timeline:\(timeline.turn)")
        }
        func bargeTimeline(_ timeline: BargeTimeline) {
            kept.withLock { $0.barges.append(timeline) }
            signals.send("barge:\(timeline.turn)")
        }
    }

    // MARK: - the audio, one event per pull

    /// The audio the coordinator reads, handed over ONE event per pull. The
    /// reader asks for event N+1 only after event N went through its body —
    /// where the speech end is stamped on arrival (D-134) — so `handOver`
    /// returning means "stamped", and the clock may move after it.
    final class Audio: Sendable {
        let stream: AsyncStream<AudioEvent>
        private let feed: Feed

        init(signals: Signals) {
            let feed = Feed(signals: signals)
            self.feed = feed
            stream = AsyncStream(unfolding: { await feed.pull() })
        }

        /// Hands `event` over and returns once the reader has asked for the
        /// NEXT one — the fact that `event` went through the reader's body.
        func handOver(_ event: AudioEvent) async -> Bool { await feed.handOver(event) }

        /// The audio ends: the reader's loop finishes.
        func end() { feed.give(nil) }
    }

    /// The feed behind `Audio`: a queue, one waiting pull, and a count of
    /// pulls announced as `pull:N`.
    final class Feed: Sendable {
        private struct State {
            var queued: [AudioEvent?] = []           // nil: the audio ended
            var waiting: CheckedContinuation<AudioEvent?, Never>?
            var cancelled = false
            var given = 0
            var pulls = 0
        }
        private let state = Mutex(State())
        private let signals: Signals

        init(signals: Signals) { self.signals = signals }

        func handOver(_ event: AudioEvent) async -> Bool {
            let number = state.withLock { state -> Int in
                state.given += 1
                return state.given
            }
            give(event)
            return await signals.heard("pull:\(number + 1)")
        }

        func give(_ event: AudioEvent?) {
            let waiter = state.withLock { state -> CheckedContinuation<AudioEvent?, Never>? in
                if let waiter = state.waiting {
                    state.waiting = nil
                    return waiter
                }
                state.queued.append(event)
                return nil
            }
            waiter?.resume(returning: event)          // outside the lock
        }

        func pull() async -> AudioEvent? {
            let number = state.withLock { state -> Int in
                state.pulls += 1
                return state.pulls
            }
            signals.send("pull:\(number)")
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<AudioEvent?, Never>) in
                    // Check and register in ONE lock step: an event given
                    // between the two would otherwise wait for ever.
                    let ready = state.withLock { state -> AudioEvent?? in
                        if !state.queued.isEmpty { return .some(state.queued.removeFirst()) }
                        if state.cancelled { return .some(nil) }
                        state.waiting = continuation
                        return .none
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            } onCancel: {
                let waiter = state.withLock { state -> CheckedContinuation<AudioEvent?, Never>? in
                    state.cancelled = true
                    defer { state.waiting = nil }
                    return state.waiting
                }
                waiter?.resume(returning: nil)
            }
        }
    }

    // MARK: - the rig

    /// A coordinator on a `ManualClock`, handed the announcing mind and mouth
    /// (`opened:N`, `tokensFinished:N`), its events forwarded as names, the
    /// audio handed over by pull, the transcripts by hand.
    struct Rig {
        let coordinator: TurnCoordinator<ManualClock>
        let clock = ManualClock()
        let signals: Signals
        let recorder: Recorder
        let generator: ScriptedReplyGenerator
        let synthesizer: ScriptedSynthesizer
        let audio: Audio
        let transcripts: AsyncStream<TranscriptEvent>.Continuation
        private let transcriptStream: AsyncStream<TranscriptEvent>
        private let forwarded: Broadcast<TurnEvent>.Listener

        init(generator: ScriptedReplyGenerator = .manual(replies: 1),
             synthesizer: ScriptedSynthesizer = .manual(utterances: 1),
             config: TurnCoordinator<ManualClock>.Config = .init(),
             quieting: Duration? = nil) async throws {
            let signals = Signals()
            self.signals = signals
            self.generator = generator
            self.synthesizer = synthesizer
            recorder = Recorder(signals: signals)
            audio = Audio(signals: signals)
            (transcriptStream, transcripts) = AsyncStream.makeStream(of: TranscriptEvent.self)
            let mouth = ToolSpikeTests.AnnouncingMouth(inner: synthesizer, signals: signals)
            let clock = clock
            let heard: any SpeechSynthesizing = if let quieting {
                SlowToSilence(inner: mouth, clock: clock, quieting: quieting)
            } else {
                mouth
            }
            coordinator = try TurnCoordinator(
                replyGenerator: ToolSpikeTests.OpenAnnouncingMind(inner: generator, signals: signals),
                synthesizer: heard,
                config: config, clock: clock, latencyReporter: recorder)
            forwarded = await coordinator.listen()
        }

        func start(in group: inout TaskGroup<Void>) {
            let coordinator = coordinator
            let audio = audio.stream
            let transcripts = transcriptStream
            group.addTask { await coordinator.run(audio: audio, transcripts: transcripts) }
            let signals = signals
            let forwarded = forwarded
            group.addTask {
                for await event in forwarded.events { signals.send(ToolSpikeTests.name(of: event)) }
            }
        }

        func heard(_ name: String) async -> Bool { await signals.heard(name) }

        /// The gate is armed: a sleeper registered on the clock — the
        /// clock's own event, raced against a cap.
        func parked() async -> Bool {
            let clock = clock
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask { await clock.waitForSleepers(atLeast: 1) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }

        func finish() async {
            audio.end()
            transcripts.finish()
            await coordinator.stop()
        }
    }

    // MARK: - one spoken turn, by hand

    /// The five stages a turn waits through before its first sound (② to
    /// ⑤ are driven here; ① is the app's hangover, and no business of the
    /// coordinator's).
    struct Stages {
        var earFinish: Duration = .milliseconds(80)
        var gate: Duration = .zero
        var firstToken: Duration = .milliseconds(120)
        var firstSound: Duration = .milliseconds(90)
    }

    /// Drives turn 0 from its onset to its FIRST SOUND, each stage exactly
    /// `stages` of manual time. `endSeen: false` leaves out the speech end.
    static func speakToFirstSound(_ rig: Rig, _ stages: Stages, endSeen: Bool = true) async {
        #expect(await rig.audio.handOver(.speechStarted(utterance: 0, at: t(0))))
        #expect(await rig.heard("listening:0"))
        if endSeen {
            #expect(await rig.audio.handOver(.speechEnded(at: t(14_400))), "the end must be stamped first")
        }
        await rig.clock.advance(by: stages.earFinish)                              // ②
        rig.transcripts.yield(.final("how far is the moon", utterance: 0, at: t(14_400)))
        if stages.gate > .zero {
            #expect(await rig.parked(), "the gate must be armed on the clock")
            await rig.clock.advance(by: stages.gate)                               // ③
        }
        #expect(await rig.heard("opened:0"), "the reply must open")
        await rig.clock.advance(by: stages.firstToken)                             // ④
        rig.generator.emit(reply: 0, token: "Far")
        #expect(await rig.heard("token:Far:0"))
        // ⑤ runs from the FIRST token: 30 ms of it pass before the second,
        // so a stamp moved to a later token would come back short.
        await rig.clock.advance(by: .milliseconds(30))                             // ⑤, part
        rig.generator.emit(reply: 0, token: "away.")
        // The second token's event proves the mouth opened on the first.
        #expect(await rig.heard("token:away.:0"))
        await rig.clock.advance(by: stages.firstSound - .milliseconds(30))         // ⑤, the rest
        rig.synthesizer.reportStarted(utterance: 0)
        #expect(await rig.heard("speaking:0"))
    }

    /// The mouth the coordinator is handed for a barge row: the announcing
    /// one, except that going SILENT takes `quieting` of manual time — a
    /// cancel that sleeps on the clock until the test moves it, so ⑧ is a
    /// number the row sets, not the zero of an instant double.
    struct SlowToSilence: SpeechSynthesizing {
        let inner: ToolSpikeTests.AnnouncingMouth
        let clock: ManualClock
        let quieting: Duration

        func openUtterance() async throws -> any SynthesisRun {
            Quieting(inner: try await inner.openUtterance(), clock: clock, quieting: quieting)
        }
    }

    struct Quieting: SynthesisRun {
        let inner: any SynthesisRun
        let clock: ManualClock
        let quieting: Duration

        var updates: AsyncStream<SynthesisUpdate> { inner.updates }
        func feed(_ token: String) async { await inner.feed(token) }
        func finishTokens() async { await inner.finishTokens() }
        func cancel() async {
            try? await clock.sleep(until: clock.now.advanced(by: quieting))
            await inner.cancel()
        }
    }

    /// Lets turn 0 finish as a person who listened to the end would.
    static func finishTurn(_ rig: Rig) async {
        rig.generator.finish(reply: 0)
        #expect(await rig.heard("tokensFinished:0"), "the mouth must be told before it reports")
        rig.synthesizer.reportFinished(utterance: 0)
        #expect(await rig.heard("completed:0"))
    }
}
