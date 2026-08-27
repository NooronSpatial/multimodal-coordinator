import Testing
import MultiModalKit
import MultiModalKitTesting

/// RED SUITE for D-024: batch engines and the overlap ruling (SPEC AC-40).
///
/// A batch engine answers in seconds, not milliseconds. Under the original
/// D-021 retirement rule its finals would die routinely — these tests encode
/// the amendment: for a `wantsWholeUtterance` engine, a settling run SURVIVES
/// the next `speechStarted` and its late final is published, tagged with its
/// own utterance number. Streaming engines keep strict retirement, proven by
/// the existing defiant test.
@Suite(.timeLimit(.minutes(1)))
struct BatchTranscriptionTests {

    static let sampleRate: Double = 48_000
    static let chunkFrames = 960

    static func t(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: sampleRate)
    }

    static func chunk(at frames: Int) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: 0.5, count: chunkFrames), start: t(frames))
    }

    /// Spin-capped gates — red fails fast, never hangs.
    @discardableResult
    static func until(_ condition: () async -> Bool, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    actor Collected {
        private(set) var events: [TranscriptEvent] = []
        func append(_ event: TranscriptEvent) { events.append(event) }
    }

    // MARK: - the amendment itself

    @Test("A batch final arriving after the next utterance began is published, tagged with its own utterance")
    func lateBatchFinalSurvivesTheNextUtterance() async {
        let engine = ScriptedTranscriber.batch(runs: 2)
        let session = TranscriptionSession(engine: engine)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            // Utterance 0: one chunk, then it ends — the "decode" begins.
            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            input.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true },
                    "utterance 0 never settled")

            // Utterance 1 begins — under the OLD rule, utterance 0 dies here.
            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            input.yield(.audioSegment(Self.chunk(at: 9600)))
            #expect(await Self.until { (engine.record(ofRun: 1)?.fedChunks.count ?? 0) >= 1 },
                    "utterance 1 never reached the engine")

            // The slow decoder finishes utterance 0 NOW — mid-utterance-1.
            engine.releaseFinal(run: 0)
            #expect(await Self.until { await box.events.count >= 1 },
                    "the late batch final was dropped — D-024 not implemented")

            // Utterance 1 completes normally.
            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { engine.record(ofRun: 1)?.audioFinished == true })
            engine.releaseFinal(run: 1)
            #expect(await Self.until { await box.events.count >= 2 },
                    "utterance 1's own final never arrived")

            input.finish()
            await session.stop()
        }

        let events = await box.events
        #expect(events == [
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960)),
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(10560))
        ], "late finals must survive, in arrival order, tagged with their own utterance")
    }

    // MARK: - stop() still silences everything

    @Test("stop() cancels settling batch runs; nothing is published after")
    func stopSilencesSettlingBatchRuns() async {
        let engine = ScriptedTranscriber.batch(runs: 1)
        let session = TranscriptionSession(engine: engine)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            input.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true })

            await session.stop()
            engine.releaseFinal(run: 0)     // the decode finishes into a stopped session
            input.finish()
        }

        #expect(await box.events == [], "a stopped session must publish nothing")
        #expect(engine.record(ofRun: 0)?.cancelled == true,
                "stop() must cancel the settling run — the optimisation half")
    }

    // MARK: - the ceiling still rules the feeding run

    @Test("The ceiling truncates a feeding batch run; its final still arrives")
    func ceilingTruncatesBatchFeedingRun() async {
        let engine = ScriptedTranscriber.batch(runs: 1)
        let session = TranscriptionSession(
            engine: engine,
            config: .init(maximumUtterance: .milliseconds(60)))   // 3 chunks
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            for i in 0..<5 { input.yield(.audioSegment(Self.chunk(at: i * Self.chunkFrames))) }
            #expect(await Self.until { await box.events.count >= 1 }, "no truncated event")

            engine.releaseFinal(run: 0)
            #expect(await Self.until { await box.events.count >= 2 }, "no final after truncation")

            input.finish()
            await session.stop()
        }

        let events = await box.events
        #expect(events == [
            .truncated(utterance: 0, at: Self.t(2880)),
            .final("u0:final(3 chunks)", utterance: 0, at: Self.t(2880))
        ])
        #expect(engine.record(ofRun: 0)?.fedChunks.count == 3)
    }

    // MARK: - graceful end drains the settling decode

    @Test("Input ending mid-decode still delivers the final, then run() returns")
    func gracefulEndWaitsForTheSettlingDecode() async {
        let engine = ScriptedTranscriber.batch(runs: 1)
        let session = TranscriptionSession(engine: engine)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            input.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true })

            input.finish()                  // the audio is over; the decode is not
            engine.releaseFinal(run: 0)
            #expect(await Self.until { await box.events.count >= 1 },
                    "graceful end must wait for the settling decode")
        }

        #expect(await box.events == [
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960))
        ])
    }
}
