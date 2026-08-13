import Testing
import MultiModalKit
import MultiModalKitTesting

/// RED SUITE for the pump (SPEC AC-9, AC-10, AC-12, AC-13, AC-17…AC-20).
///
/// Every test drives fake audio through a real ring and fake time through the
/// ManualClock. No sleeps, no wall clock, no "wait a bit and hope": the tests
/// gate on facts (the pump parked on the clock; the stream finished), and
/// every wait has a spin cap so a red test fails fast instead of hanging.
@Suite(.timeLimit(.minutes(1)))
struct AudioPumpTests {

    // MARK: - fixture

    static let sampleRate: Double = 48_000
    static let chunkFrames = 960          // 20 ms at 48 kHz
    static let loud: Float = 0.5          // RMS 0.5 — binary exact, above threshold
    static let quiet: Float = 0.0
    static let threshold: Float = 0.25    // binary exact on purpose

    struct Fixture {
        let producer: AudioRingProducer
        let pump: AudioPump<ManualClock>
        let clock: ManualClock
    }

    static func makeFixture(
        ringCapacity: Int = 1 << 15,
        hangoverChunks: Int = 2,
        preRollChunks: Int = 2
    ) -> Fixture {
        let ring = AudioRing.create(minimumCapacity: ringCapacity)
        let clock = ManualClock()
        let vad = EnergyVAD(
            config: .init(threshold: threshold, hangoverFrames: hangoverChunks * chunkFrames)
        )
        let pump = AudioPump(
            consumer: ring.consumer,
            vad: vad,
            clock: clock,
            config: .init(
                sampleRate: sampleRate,
                pollInterval: .milliseconds(10),
                chunkFrames: chunkFrames,
                preRollChunks: preRollChunks
            )
        )
        return Fixture(producer: ring.producer, pump: pump, clock: clock)
    }

    /// Writes `frames` samples of one value — the microphone's side of the ring.
    static func write(_ producer: AudioRingProducer, _ value: Float, frames: Int) {
        let samples = [Float](repeating: value, count: frames)
        samples.withUnsafeBufferPointer { producer.write($0) }
    }

    /// Waits until the pump is parked on the clock. Spin-capped: a red pump
    /// that never sleeps fails this in milliseconds instead of hanging.
    @discardableResult
    static func parked(_ clock: ManualClock, atLeast count: Int = 1, spins: Int = 20_000) async -> Bool {
        for _ in 0..<spins {
            if clock.sleeperCount >= count { return true }
            await Task.yield()
        }
        return false
    }

    /// Drains a finished stream into an array. Capped, so a stream that never
    /// finishes cannot hang the suite alone (the time limit is the backstop).
    static func collect(_ stream: AsyncStream<AudioEvent>, cap: Int = 500) async -> [AudioEvent] {
        var out: [AudioEvent] = []
        for await event in stream {
            out.append(event)
            if out.count >= cap { break }
        }
        return out
    }

    static func t(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: sampleRate)
    }

    static func chunk(_ value: Float, at frames: Int) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: chunkFrames), start: t(frames))
    }

    // MARK: - AC-9 / AC-18: the rhythm, and a clean stop

    @Test("The pump parks on the injected clock, wakes on each poll, and leaves nothing behind")
    func pumpParksWakesAndStopsClean() async {
        let f = Self.makeFixture()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }

            #expect(await Self.parked(f.clock), "the pump never parked on the injected clock")

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock), "the pump did not park again after one poll")

            await f.pump.stop()
            group.cancelAll()
        }

        #expect(f.clock.sleeperCount == 0, "a sleeper survived stop()")
    }

    @Test("stop() alone ends the loop — no cancellation, no clock advance")
    func stopAloneEndsTheLoop() async {
        let f = Self.makeFixture()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock), "the pump never parked on the injected clock")

            await f.pump.stop()
            // Deliberately no cancelAll() and no advance(): the group can only
            // finish here if stop() woke the parked loop by itself (D-014).
        }

        #expect(f.clock.sleeperCount == 0, "a sleeper survived stop()")
    }

    // MARK: - AC-12 / AC-17 / AC-19: the full utterance, exactly

    @Test("A scripted utterance produces the exact event sequence, in timeline order")
    func scriptedUtteranceProducesTheExactEventSequence() async {
        let f = Self.makeFixture()
        let listener = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.quiet, frames: 2 * Self.chunkFrames)  // pre-roll material
            Self.write(f.producer, Self.loud, frames: 3 * Self.chunkFrames)   // the words
            Self.write(f.producer, Self.quiet, frames: 2 * Self.chunkFrames)  // exactly the hangover

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .speechStarted(utterance: 0, at: Self.t(1920)),           // the first loud chunk's own moment
            .audioSegment(Self.chunk(Self.quiet, at: 0)),     // pre-roll, older than the start
            .audioSegment(Self.chunk(Self.quiet, at: 960)),
            .audioSegment(Self.chunk(Self.loud, at: 1920)),
            .audioSegment(Self.chunk(Self.loud, at: 2880)),
            .audioSegment(Self.chunk(Self.loud, at: 3840)),
            .audioSegment(Self.chunk(Self.quiet, at: 4800)),  // tail: still speech, hangover running
            .audioSegment(Self.chunk(Self.quiet, at: 5760)),
            .speechEnded(at: Self.t(6720)),            // the hangover is spent
        ])
    }

    // MARK: - AC-19: the first syllable survives

    @Test("Only the last two held chunks are pre-rolled, and they arrive before the live audio")
    func preRollDeliversTheChunksRecordedBeforeSpeech() async {
        let f = Self.makeFixture()
        let listener = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.quiet, frames: 4 * Self.chunkFrames)  // four quiet chunks
            Self.write(f.producer, Self.loud, frames: 1 * Self.chunkFrames)

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .speechStarted(utterance: 0, at: Self.t(3840)),
            .audioSegment(Self.chunk(Self.quiet, at: 1920)),  // the two NEWEST quiet chunks only
            .audioSegment(Self.chunk(Self.quiet, at: 2880)),
            .audioSegment(Self.chunk(Self.loud, at: 3840)),
        ])
    }

    // MARK: - AC-17: a partial chunk is carried, never padded

    @Test("A partial chunk waits for the next poll instead of being padded or judged")
    func partialChunkIsCarriedToTheNextPoll() async {
        let f = Self.makeFixture()
        let listener = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.loud, frames: 1440)   // one chunk and a half
            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.loud, frames: 480)    // completes the second chunk
            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .speechStarted(utterance: 0, at: Self.t(0)),
            .audioSegment(Self.chunk(Self.loud, at: 0)),
            .audioSegment(Self.chunk(Self.loud, at: 960)),
        ])
    }

    // MARK: - AC-13 / D-010: losses are events, with exact counts

    @Test("Frames lost to a full ring appear as a dropped event with the exact count")
    func droppedFramesAppearAsAnEventWithTheExactCount() async {
        let f = Self.makeFixture(ringCapacity: 2048)
        let listener = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            // Three honest microphone-sized writes: the ring's contract is
            // that ONE write never exceeds capacity (asserted in AudioRingBuffer).
            // 3072 written into a 2048 ring ⇒ exactly 1024 frames lost.
            for _ in 0..<3 { Self.write(f.producer, Self.loud, frames: 1024) }

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .dropped(frames: 1024, at: Self.t(0)),      // the gap, where it happened
            .speechStarted(utterance: 0, at: Self.t(1024)),           // audio time counts the lost frames
            .audioSegment(Self.chunk(Self.loud, at: 1024)),
            .audioSegment(Self.chunk(Self.loud, at: 1984)),
        ])
    }

    // MARK: - AC-20: every listener sees the same thing

    @Test("Two listeners receive identical sequences")
    func everyListenerSeesTheSameSequence() async {
        let f = Self.makeFixture()
        let first = await f.pump.listen()
        let second = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.loud, frames: 2 * Self.chunkFrames)

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let a = await Self.collect(first.events)
        let b = await Self.collect(second.events)
        #expect(a == b)
        #expect(a.first == .speechStarted(utterance: 0, at: Self.t(0)))
        #expect(a.count == 3)
    }

    // MARK: - AC-13: capture-to-speechStarted is an exact number, not a measurement

    @Test("Latency from capture to speechStarted is exact audio time")
    func latencyFromCaptureToSpeechStartedIsExact() async {
        let f = Self.makeFixture()
        let listener = await f.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await f.pump.run() }
            #expect(await Self.parked(f.clock))

            Self.write(f.producer, Self.quiet, frames: 2 * Self.chunkFrames)
            Self.write(f.producer, Self.loud, frames: 1 * Self.chunkFrames)

            await f.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(f.clock))

            await f.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        guard case .speechStarted(_, let at)? = events.first else {
            Issue.record("no speechStarted event")
            return
        }
        #expect(at.frames == 1920)
        #expect(at.seconds == 0.04)   // 1920 / 48000, exactly
    }
}
