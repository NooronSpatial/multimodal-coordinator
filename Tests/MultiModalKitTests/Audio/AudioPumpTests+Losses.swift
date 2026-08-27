import Testing
import MultiModalKit
import MultiModalKitTesting

// The second half of `AudioPumpTests`, in an extension so neither file
// hides a test behind a scroll bar: losses, the multicast, exact capture
// timing, and 1d's onset window.
extension AudioPumpTests {

    // MARK: - AC-13 / D-010: losses are events, with exact counts

    @Test("Frames lost to a full ring appear as a dropped event with the exact count")
    func droppedFramesAppearAsAnEventWithTheExactCount() async {
        let fixture = Self.makeFixture(ringCapacity: 2048)
        let listener = await fixture.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.pump.run() }
            #expect(await Self.parked(fixture.clock))

            // Three honest microphone-sized writes: the ring's contract is
            // that ONE write never exceeds capacity (asserted in AudioRingBuffer).
            // 3072 written into a 2048 ring ⇒ exactly 1024 frames lost.
            for _ in 0..<3 { Self.write(fixture.producer, Self.loud, frames: 1024) }

            await fixture.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(fixture.clock))

            await fixture.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .dropped(frames: 1024, at: Self.t(0)),      // the gap, where it happened
            .speechStarted(utterance: 0, at: Self.t(1024)),           // audio time counts the lost frames
            .audioSegment(Self.chunk(Self.loud, at: 1024)),
            .audioSegment(Self.chunk(Self.loud, at: 1984))
        ])
    }

    // MARK: - AC-20: every listener sees the same thing

    @Test("Two listeners receive identical sequences")
    func everyListenerSeesTheSameSequence() async {
        let fixture = Self.makeFixture()
        let first = await fixture.pump.listen()
        let second = await fixture.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.pump.run() }
            #expect(await Self.parked(fixture.clock))

            Self.write(fixture.producer, Self.loud, frames: 2 * Self.chunkFrames)

            await fixture.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(fixture.clock))

            await fixture.pump.stop()
            group.cancelAll()
        }

        let firstEvents = await Self.collect(first.events)
        let secondEvents = await Self.collect(second.events)
        #expect(firstEvents == secondEvents)
        #expect(firstEvents.first == .speechStarted(utterance: 0, at: Self.t(0)))
        #expect(firstEvents.count == 3)
    }

    // MARK: - AC-13: capture-to-speechStarted is an exact number, not a measurement

    @Test("Latency from capture to speechStarted is exact audio time")
    func latencyFromCaptureToSpeechStartedIsExact() async {
        let fixture = Self.makeFixture()
        let listener = await fixture.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.pump.run() }
            #expect(await Self.parked(fixture.clock))

            Self.write(fixture.producer, Self.quiet, frames: 2 * Self.chunkFrames)
            Self.write(fixture.producer, Self.loud, frames: 1 * Self.chunkFrames)

            await fixture.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(fixture.clock))

            await fixture.pump.stop()
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

    // MARK: - 1d: the onset window through the pump (AC-76, AC-73, D-035)

    @Test("With the window wired per the F-4 law, the word is not beheaded")
    func onsetWindowDeliversTheFullWordThroughPreRoll() async {
        // Window = 3 chunks; pre-roll = 3 (the wiring law: pre-roll ≥ window).
        // During candidacy the pump still believes "quiet", so the first two
        // loud chunks — the true start of the word — sit on the pre-roll
        // shelf and must come back out when the third chunk fires the start.
        let fixture = Self.makeFixture(preRollChunks: 3, onsetChunks: 3)
        let listener = await fixture.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.pump.run() }
            #expect(await Self.parked(fixture.clock))

            Self.write(fixture.producer, Self.quiet, frames: 1 * Self.chunkFrames)  // run-up quiet
            Self.write(fixture.producer, Self.loud, frames: 3 * Self.chunkFrames)   // exactly the window
            Self.write(fixture.producer, Self.quiet, frames: 2 * Self.chunkFrames)  // exactly the hangover

            await fixture.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(fixture.clock))

            await fixture.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [
            .speechStarted(utterance: 0, at: Self.t(2880)),   // the COMPLETING chunk's moment (F-3)
            .audioSegment(Self.chunk(Self.quiet, at: 0)),     // pre-roll: the quiet run-up…
            .audioSegment(Self.chunk(Self.loud, at: 960)),    // …and the word's true start,
            .audioSegment(Self.chunk(Self.loud, at: 1920)),   // held during candidacy
            .audioSegment(Self.chunk(Self.loud, at: 2880)),   // the chunk that fired
            .audioSegment(Self.chunk(Self.quiet, at: 3840)),  // hangover tail
            .audioSegment(Self.chunk(Self.quiet, at: 4800)),
            .speechEnded(at: Self.t(5760))
        ])
    }

    @Test("A sub-window transient publishes nothing — nothing for the turn loop to barge on")
    func subWindowTransientPublishesNothing() async {
        // The turn-loop interplay proof: barge-in IS the pump's speechStarted
        // (D-031). Zero events here means a click provably cannot reach any
        // coordinator, in any state — there is no event to act on.
        let fixture = Self.makeFixture(preRollChunks: 3, onsetChunks: 3)
        let listener = await fixture.pump.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.pump.run() }
            #expect(await Self.parked(fixture.clock))

            Self.write(fixture.producer, Self.loud, frames: 2 * Self.chunkFrames)   // one short of the window
            Self.write(fixture.producer, Self.quiet, frames: 6 * Self.chunkFrames)  // long silence after

            await fixture.clock.advance(by: .milliseconds(10))
            #expect(await Self.parked(fixture.clock))

            await fixture.pump.stop()
            group.cancelAll()
        }

        let events = await Self.collect(listener.events)
        #expect(events == [], "a transient leaked \(events.count) event(s) past the window")
    }
}
