import Testing
import MultiModalKit

/// RED SUITE for the transcription session (SPEC AC-23…AC-32).
///
/// No clocks anywhere: the session is clockless by design — time lives in the
/// audio. Tests feed `AudioEvent`s step by step and GATE ON PUBLISHED EVENTS
/// (never on counts or delays) before feeding more, so every expected sequence
/// is exact. Every wait is spin-capped: red fails fast, never hangs.
@Suite(.timeLimit(.minutes(1)))
struct TranscriptionSessionTests {

    static let sampleRate: Double = 48_000
    static let chunkFrames = 960                        // 20 ms at 48 kHz

    // MARK: - fixture

    /// A hand-driven stand-in for the pump: yields audio events on demand.
    struct Feed {
        let stream: AsyncStream<AudioEvent>
        let continuation: AsyncStream<AudioEvent>.Continuation

        init() {
            var handle: AsyncStream<AudioEvent>.Continuation!
            stream = AsyncStream { handle = $0 }
            continuation = handle
        }

        func yield(_ event: AudioEvent) { continuation.yield(event) }
        func finish() { continuation.finish() }
    }

    /// An event collector that can be QUERIED mid-stream — the gating tool.
    actor Collected {
        private(set) var events: [TranscriptEvent] = []
        func append(_ event: TranscriptEvent) { events.append(event) }
    }

    static func t(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: sampleRate)
    }

    static func chunk(at frames: Int, value: Float = 0.5) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: chunkFrames), start: t(frames))
    }

    /// Waits (spin-capped) until the collector holds at least `count` events.
    @discardableResult
    static func collected(_ box: Collected, atLeast count: Int, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if await box.events.count >= count { return true }
            await Task.yield()
        }
        return false
    }

    /// Waits (spin-capped) until the engine has fed `count` chunks to `run`.
    @discardableResult
    static func fed(_ engine: ScriptedTranscriber, run: Int, atLeast count: Int, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if (engine.record(ofRun: run)?.fedChunks.count ?? 0) >= count { return true }
            await Task.yield()
        }
        return false
    }

    /// Runs one scripted conversation: a session consuming `feed.stream`,
    /// a collector task reading one listener, and the test body in between.
    static func withSession(
        engine: ScriptedTranscriber,
        config: TranscriptionSession.Config = .init(),
        body: (TranscriptionSession, Feed, Collected) async -> Void
    ) async -> [TranscriptEvent] {
        let session = TranscriptionSession(engine: engine, config: config)
        let feed = Feed()
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed.stream) }
            group.addTask {
                for await event in listener.events { await box.append(event) }
            }
            await body(session, feed, box)
            feed.finish()
            await session.stop()
        }
        return await box.events
    }

    // MARK: - AC-23 / AC-24: one run per utterance, pre-roll fed first, once, in order

    @Test("One utterance opens one run and feeds it every chunk, pre-roll first")
    func oneUtteranceFeedsOneRunInOrder() async {
        let engine = ScriptedTranscriber(plans: [.normal(partialEveryChunks: 100)])

        _ = await Self.withSession(engine: engine) { _, feed, _ in
            feed.yield(.speechStarted(at: Self.t(1920)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))      // pre-roll (older)
            feed.yield(.audioSegment(Self.chunk(at: 960)))    // pre-roll
            feed.yield(.audioSegment(Self.chunk(at: 1920)))   // live
            feed.yield(.speechEnded(at: Self.t(2880)))
            _ = await Self.fed(engine, run: 0, atLeast: 3)
        }

        #expect(engine.runsOpened == 1)
        let record = engine.record(ofRun: 0)
        #expect(record?.fedChunks.map(\.start.frames) == [0, 960, 1920], "every chunk once, in order, pre-roll first")
        #expect(record?.audioFinished == true, "speechEnded must settle the run")
    }

    // MARK: - AC-27 / AC-28 / AC-31: partials, the final, and exact audio time

    @Test("A scripted utterance publishes partials and a final with exact audio times")
    func partialsAndFinalCarryExactAudioTime() async {
        let engine = ScriptedTranscriber(plans: [.normal(partialEveryChunks: 2)])

        let events = await Self.withSession(engine: engine) { _, feed, box in
            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            feed.yield(.audioSegment(Self.chunk(at: 960)))     // 2nd chunk → partial
            #expect(await Self.collected(box, atLeast: 1), "no partial arrived")

            feed.yield(.audioSegment(Self.chunk(at: 1920)))
            feed.yield(.audioSegment(Self.chunk(at: 2880)))    // 4th chunk → partial
            #expect(await Self.collected(box, atLeast: 2))

            feed.yield(.speechEnded(at: Self.t(3840)))         // settle → final
            #expect(await Self.collected(box, atLeast: 3))
        }

        #expect(events == [
            .partial("u0:p1", utterance: 0, at: Self.t(1920)),   // after 2 chunks fed
            .partial("u0:p2", utterance: 0, at: Self.t(3840)),   // after 4 chunks fed
            .final("u0:final(4 chunks)", utterance: 0, at: Self.t(3840)),
        ])
    }

    // MARK: - AC-25: the ticket — the defiant engine cannot reach a listener

    @Test("A late final from a dead utterance is dropped; the next utterance is untouched")
    func lateFinalFromDeadUtteranceIsDropped() async {
        let engine = ScriptedTranscriber(plans: [
            .silent,                            // utterance 0: never answers, ignores cancel
            .normal(partialEveryChunks: 100),   // utterance 1: behaves
        ])

        let events = await Self.withSession(engine: engine) { _, feed, box in
            // Utterance 0 comes and goes; the silent engine never speaks.
            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            feed.yield(.speechEnded(at: Self.t(960)))

            // Utterance 1 begins — utterance 0 is now dead.
            feed.yield(.speechStarted(at: Self.t(4800)))
            feed.yield(.audioSegment(Self.chunk(at: 4800)))
            _ = await Self.fed(engine, run: 1, atLeast: 1)

            // The defiant move: run 0 answers NOW, into a dead utterance.
            engine.forceFinal(run: 0, text: "u0:too-late")

            // Utterance 1 completes normally.
            feed.yield(.speechEnded(at: Self.t(5760)))
            #expect(await Self.collected(box, atLeast: 1), "utterance 1's final never arrived")
        }

        #expect(events == [
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(5760)),
        ], "the dead utterance's text leaked — the ticket failed")
    }

    // MARK: - AC-29: failure is an event, and the session survives it

    @Test("A run that fails mid-utterance publishes failed; the next utterance transcribes")
    func failureIsAnEventAndTheSessionSurvives() async {
        let spikeFailure = TranscriptionFailure.assetDownloadFailed(
            "transcription.en asset unavailable after attempted download, final state: Network Error")
        let engine = ScriptedTranscriber(plans: [
            .failWhileRunning(afterChunks: 2, spikeFailure),
            .normal(partialEveryChunks: 100),
        ])

        let events = await Self.withSession(engine: engine) { _, feed, box in
            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            feed.yield(.audioSegment(Self.chunk(at: 960)))     // 2nd chunk → the engine dies
            #expect(await Self.collected(box, atLeast: 1), "no failed event arrived")
            feed.yield(.speechEnded(at: Self.t(1920)))

            feed.yield(.speechStarted(at: Self.t(4800)))
            feed.yield(.audioSegment(Self.chunk(at: 4800)))
            feed.yield(.speechEnded(at: Self.t(5760)))
            #expect(await Self.collected(box, atLeast: 2), "the session did not survive the failure")
        }

        #expect(events == [
            .failed(spikeFailure, utterance: 0, at: Self.t(1920)),
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(5760)),
        ])
    }

    @Test("An engine that cannot even open a run yields failed, and the session lives on")
    func openFailureIsAnEventToo() async {
        let engine = ScriptedTranscriber(plans: [
            .failOnOpen(.modelNotInstalled),
            .normal(partialEveryChunks: 100),
        ])

        let events = await Self.withSession(engine: engine) { _, feed, box in
            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            feed.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.collected(box, atLeast: 1), "no failed event for the unopenable run")

            feed.yield(.speechStarted(at: Self.t(4800)))
            feed.yield(.audioSegment(Self.chunk(at: 4800)))
            feed.yield(.speechEnded(at: Self.t(5760)))
            #expect(await Self.collected(box, atLeast: 2))
        }

        #expect(events == [
            .failed(.modelNotInstalled, utterance: 0, at: Self.t(0)),
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(5760)),
        ])
    }

    // MARK: - AC-26: the ceiling

    @Test("An utterance longer than the ceiling is cut with truncated, audio released")
    func overlongUtteranceIsTruncated() async {
        // Ceiling of 60 ms = 3 chunks. The 4th chunk must not reach the engine.
        let engine = ScriptedTranscriber(plans: [.normal(partialEveryChunks: 100)])
        let config = TranscriptionSession.Config(maximumUtterance: .milliseconds(60))

        let events = await Self.withSession(engine: engine, config: config) { _, feed, box in
            feed.yield(.speechStarted(at: Self.t(0)))
            for i in 0..<5 {
                feed.yield(.audioSegment(Self.chunk(at: i * Self.chunkFrames)))
            }
            #expect(await Self.collected(box, atLeast: 1), "no truncated event arrived")
            feed.yield(.speechEnded(at: Self.t(5 * Self.chunkFrames)))
        }

        #expect(events.first == .truncated(utterance: 0, at: Self.t(3 * Self.chunkFrames)))
        #expect(engine.record(ofRun: 0)?.fedChunks.count == 3, "audio beyond the ceiling reached the engine")
        #expect(engine.record(ofRun: 0)?.audioFinished == true, "the cut must settle the run for its final")
    }

    // MARK: - AC-30: multicast

    @Test("Two listeners receive identical transcript sequences")
    func twoListenersReceiveIdenticalSequences() async {
        let engine = ScriptedTranscriber(plans: [.normal(partialEveryChunks: 100)])
        let session = TranscriptionSession(engine: engine)
        let feed = Feed()
        let first = await session.listen()
        let second = await session.listen()

        let boxA = Collected()
        let boxB = Collected()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed.stream) }
            group.addTask { for await event in first.events { await boxA.append(event) } }
            group.addTask { for await event in second.events { await boxB.append(event) } }

            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            feed.yield(.speechEnded(at: Self.t(960)))

            // Gate on the PUBLISHED final — stop() is hard by definition, so
            // stopping before the gate would rightly destroy the event.
            #expect(await Self.collected(boxA, atLeast: 1), "listener A never got the final")
            #expect(await Self.collected(boxB, atLeast: 1), "listener B never got the final")

            feed.finish()
            await session.stop()
        }

        let a = await boxA.events
        let b = await boxB.events
        #expect(a == b)
        #expect(a == [.final("u0:final(1 chunks)", utterance: 0, at: Self.t(960))])
    }

    // MARK: - AC-32: shutdown

    @Test("stop() mid-recognition finishes every stream and cancels the open run")
    func stopMidRecognitionEndsCleanly() async {
        let engine = ScriptedTranscriber(plans: [.normal(partialEveryChunks: 100)])

        let events = await Self.withSession(engine: engine) { session, feed, _ in
            feed.yield(.speechStarted(at: Self.t(0)))
            feed.yield(.audioSegment(Self.chunk(at: 0)))
            _ = await Self.fed(engine, run: 0, atLeast: 1)
            await session.stop()          // mid-utterance, no speechEnded
        }

        #expect(events == [], "nothing may be published after stop")
        #expect(engine.record(ofRun: 0)?.cancelled == true, "the open run must be cancelled on stop")
    }
}
