import Testing
import MultiModalKit
import MultiModalKitTesting

/// RED SUITE for the diagnostics seam (SPEC AC-48…AC-50, D-026/D-027).
///
/// Everything here is deterministic: thermal states are pushed by hand
/// through the scripted provider, reports are made by direct calls, and
/// every wait gates on a published event with a spin cap — red fails fast.
@Suite(.timeLimit(.minutes(1)))
struct DiagnosticsTests {

    actor Collected {
        private(set) var events: [HealthEvent] = []
        func append(_ event: HealthEvent) { events.append(event) }
    }

    @discardableResult
    static func until(_ condition: () async -> Bool, spins: Int = 40_000) async -> Bool {
        for _ in 0..<spins {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    static func t(_ frames: Int) -> AudioTime {
        AudioTime(frames: frames, sampleRate: 48_000)
    }

    /// Runs diagnostics with a scripted thermometer; the body drives, the
    /// collector records, stop() ends everything.
    static func withDiagnostics(
        initial: ThermalState = .nominal,
        body: (PipelineDiagnostics, ScriptedThermalProvider, Collected) async -> Void
    ) async -> [HealthEvent] {
        let thermometer = ScriptedThermalProvider(initial: initial)
        let diagnostics = PipelineDiagnostics(thermal: thermometer)
        let box = Collected()
        let listener = diagnostics.health()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await diagnostics.run() }
            group.addTask { for await event in listener.events { await box.append(event) } }

            await body(diagnostics, thermometer, box)

            thermometer.finish()
            diagnostics.stop()
        }
        return await box.events
    }

    // MARK: - AC-49: the thermal story, scripted

    @Test("The baseline is published on start, then every transition, in order")
    func thermalBaselineAndTransitions() async {
        let events = await Self.withDiagnostics(initial: .fair) { _, thermometer, box in
            #expect(await Self.until { await box.events.count >= 1 }, "no baseline published")
            thermometer.push(.serious)
            thermometer.push(.critical)
            thermometer.push(.nominal)
            #expect(await Self.until { await box.events.count >= 4 })
        }

        #expect(events == [
            .thermal(.fair),          // the baseline — a listener knows NOW, not eventually
            .thermal(.serious),
            .thermal(.critical),
            .thermal(.nominal),
        ])
    }

    // MARK: - AC-48: the pipeline's reports become events

    @Test("Ring drops are mirrored exactly, where and as reported")
    func ringDropsAreMirrored() async {
        let events = await Self.withDiagnostics { diagnostics, _, box in
            #expect(await Self.until { await box.events.count >= 1 })   // baseline
            diagnostics.noteRingDrop(frames: 4_800, at: Self.t(96_000))
            #expect(await Self.until { await box.events.count >= 2 }, "the drop never surfaced")
        }

        #expect(events.dropFirst().first == .ringDropped(frames: 4_800, at: Self.t(96_000)))
    }

    @Test("Settling count publishes only on change")
    func settlingCountPublishesOnlyOnChange() async {
        let events = await Self.withDiagnostics { diagnostics, _, box in
            #expect(await Self.until { await box.events.count >= 1 })   // baseline
            diagnostics.noteSettlingDecodes(count: 1)
            diagnostics.noteSettlingDecodes(count: 1)   // same — must be silent
            diagnostics.noteSettlingDecodes(count: 2)
            diagnostics.noteSettlingDecodes(count: 0)
            #expect(await Self.until { await box.events.count >= 4 })
        }

        #expect(Array(events.dropFirst()) == [
            .settlingDecodes(count: 1),
            .settlingDecodes(count: 2),
            .settlingDecodes(count: 0),
        ], "a repeated count must not repeat the event")
    }

    @Test("A slow listener's losses become visible to everyone else")
    func listenerLossIsReported() async {
        let events = await Self.withDiagnostics { diagnostics, _, box in
            #expect(await Self.until { await box.events.count >= 1 })   // baseline
            diagnostics.noteListenerLoss(listenerID: 3, totalDropped: 7)
            #expect(await Self.until { await box.events.count >= 2 })
        }

        #expect(events.dropFirst().first == .listenerFellBehind(listenerID: 3, totalDropped: 7))
    }

    // MARK: - D-012 rules hold for health too

    @Test("A late health listener hears only what comes next — no replay")
    func lateListenerGetsNoReplay() async {
        let thermometer = ScriptedThermalProvider(initial: .nominal)
        let diagnostics = PipelineDiagnostics(thermal: thermometer)
        let early = diagnostics.health()
        let earlyBox = Collected()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await diagnostics.run() }
            group.addTask { for await event in early.events { await earlyBox.append(event) } }

            #expect(await Self.until { await earlyBox.events.count >= 1 })  // baseline seen by early

            let late = diagnostics.health()                                 // subscribes AFTER
            let lateBox = Collected()
            group.addTask { for await event in late.events { await lateBox.append(event) } }

            diagnostics.noteSettlingDecodes(count: 1)
            #expect(await Self.until { await lateBox.events.count >= 1 })

            let lateEvents = await lateBox.events
            #expect(lateEvents == [.settlingDecodes(count: 1)],
                    "the late listener must NOT receive the replayed baseline")

            thermometer.finish()
            diagnostics.stop()
        }
    }

    // MARK: - shutdown

    @Test("stop() finishes every health stream; run() returns when the provider ends")
    func stopEndsCleanly() async {
        let thermometer = ScriptedThermalProvider(initial: .nominal)
        let diagnostics = PipelineDiagnostics(thermal: thermometer)
        let listener = diagnostics.health()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await diagnostics.run() }

            diagnostics.stop()
            thermometer.finish()
            // The group is the wall: it can only exit if run() returned and
            // the listener's stream finished.
            for await _ in listener.events {}
        }
        #expect(Bool(true), "reaching here IS the assertion: nothing hung")
    }
}

/// Integration: the PIPELINE reports, not just the seam (AC-48 end to end).
@Suite(.timeLimit(.minutes(1)))
struct DiagnosticsWiringTests {

    actor Collected {
        private(set) var events: [HealthEvent] = []
        func append(_ event: HealthEvent) { events.append(event) }
    }

    @Test("The pump mirrors ring drops into health, same numbers, same stamp")
    func pumpMirrorsRingDrops() async {
        let diagnostics = PipelineDiagnostics(thermal: ScriptedThermalProvider())
        let ring = AudioRing.create(minimumCapacity: 2048)
        let clock = ManualClock()
        let pump = AudioPump(
            consumer: ring.consumer,
            vad: EnergyVAD(config: .init(threshold: 0.25, hangoverFrames: 1920)),
            clock: clock,
            config: .init(sampleRate: 48_000, pollInterval: .milliseconds(10),
                          chunkFrames: 960, preRollChunks: 2),
            diagnostics: diagnostics)
        let box = Collected()
        let health = diagnostics.health()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump.run() }
            group.addTask { for await event in health.events { await box.append(event) } }

            for _ in 0..<40_000 {
                if clock.sleeperCount >= 1 { break }
                await Task.yield()
            }
            // 3072 frames into a 2048 ring ⇒ exactly 1024 lost (the ring's contract:
            // three microphone-sized writes).
            let samples = [Float](repeating: 0.5, count: 1024)
            for _ in 0..<3 { samples.withUnsafeBufferPointer { ring.producer.write($0) } }
            await clock.advance(by: .milliseconds(10))

            #expect(await DiagnosticsTests.until { await !box.events.isEmpty },
                    "the drop never reached health")
            await pump.stop()
            diagnostics.stop()
        }

        #expect(await box.events.first == .ringDropped(
            frames: 1024, at: AudioTime(frames: 0, sampleRate: 48_000)))
    }

    @Test("The session's settling table reports its count changes")
    func sessionReportsSettlingCounts() async {
        let diagnostics = PipelineDiagnostics(thermal: ScriptedThermalProvider())
        let engine = ScriptedTranscriber.batch(runs: 2)
        let session = TranscriptionSession(engine: engine, diagnostics: diagnostics)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let health = diagnostics.health()
        func t(_ frames: Int) -> AudioTime { AudioTime(frames: frames, sampleRate: 48_000) }
        func chunk(at frames: Int) -> AudioChunk {
            AudioChunk(samples: [Float](repeating: 0.5, count: 960), start: t(frames))
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in health.events { await box.append(event) } }

            input.yield(.speechStarted(utterance: 0, at: t(0)))
            input.yield(.audioSegment(chunk(at: 0)))
            input.yield(.speechEnded(at: t(960)))
            #expect(await DiagnosticsTests.until { engine.record(ofRun: 0)?.audioFinished == true })

            input.yield(.speechStarted(utterance: 1, at: t(9600)))       // №0 moves to settling → count 1
            #expect(await DiagnosticsTests.until { await box.events.contains(.settlingDecodes(count: 1)) },
                    "the settling count never rose")

            engine.releaseFinal(run: 0)                    // №0's final → count 0
            #expect(await DiagnosticsTests.until { await box.events.contains(.settlingDecodes(count: 0)) },
                    "the settling count never fell")

            input.finish()
            await session.stop()
            diagnostics.stop()
        }

        let settling = await box.events.filter {
            if case .settlingDecodes = $0 { true } else { false }
        }
        #expect(settling == [.settlingDecodes(count: 1), .settlingDecodes(count: 0)])
    }
}
