import Testing
import MultiModalKit
import MultiModalKitTesting

/// `ThermalPolicyTests`, continued. Topic: the full mid-session story — heat
/// arriving between two settling moves — and the fixture it stands on.
extension ThermalPolicyTests {

    // MARK: - the full story: transition mid-session, count > 0, survivors

    @Test("Heat arriving mid-session: earlier settling decode survives, the next move is refused with exact inputs")
    func midSessionHeatRefusesNewMovesButSparesSurvivors() async {
        let fixture = await MidSessionHeatFixture.make()
        let engine = fixture.engine
        let input = fixture.input
        let box = fixture.box
        let healthBox = fixture.healthBox

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await fixture.session.run(events: fixture.feed) }
            group.addTask { for await event in fixture.listener.events { await box.append(event) } }
            group.addTask { for await event in fixture.health.events { await healthBox.append(event) } }

            // Utterance 0 settles on a FAIR device...
            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            input.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true })

            // ...and utterance 1's barge moves it to the settling table:
            // the policy allowed it, seeing (.fair, 0).
            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            input.yield(.audioSegment(Self.chunk(at: 9600)))
            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { engine.record(ofRun: 1)?.audioFinished == true })

            // THE DEVICE HEATS UP — then utterance 2 barges in. The policy
            // sees (.serious, 1): utterance 1's move is refused...
            fixture.provider.push(.serious)
            input.yield(.speechStarted(utterance: 2, at: Self.t(19200)))
            #expect(await Self.until { await box.events.contains {
                if case .failed(.declinedUnderThermalPressure, 1, _) = $0 { return true }
                return false
            } }, "the second settling move must be refused at .serious")

            // ...but utterance 0 — ALREADY settling — was never touched:
            // its slow decode finishes and its final surfaces.
            engine.releaseFinal(run: 0)
            #expect(await Self.until { await box.events.contains {
                if case .final(_, 0, _) = $0 { return true } else { return false }
            } }, "an already-settling decode survives later refusals")

            // Utterance 2 is live work: untouched by any of it.
            input.yield(.audioSegment(Self.chunk(at: 19200)))
            input.yield(.speechEnded(at: Self.t(20160)))
            #expect(await Self.until { engine.record(ofRun: 2)?.audioFinished == true })
            engine.releaseFinal(run: 2)
            #expect(await Self.until { await box.events.count >= 3 })

            input.finish()
            await fixture.session.stop()
            fixture.diagnostics.stop()
        }

        #expect(await box.events == [
            .failed(.declinedUnderThermalPressure, utterance: 1, at: Self.t(10560)),
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960)),
            .final("u2:final(1 chunks)", utterance: 2, at: Self.t(20160))
        ])

        // The record: two consultations, exact inputs, the transition seen.
        let calls = fixture.policy.recorded
        #expect(calls.count == 2)
        #expect(calls.first ?? (.critical, -1) == (.fair, 0))
        #expect(calls.last ?? (.critical, -1) == (.serious, 1),
                "the policy must see the CURRENT heat and the CURRENT settling count")
        #expect(await healthBox.events.contains(
            .settlingDecodeRefused(utterance: 1, thermal: .serious)))
    }
}

/// The story's fixture, assembled in one place so the test body stays the
/// story: a heat source that starts `.fair`, a three-run batch engine, a
/// policy that records every consultation while the shipped default rules,
/// and the two collectors, already listening.
private struct MidSessionHeatFixture {
    let provider: ScriptedThermalProvider
    let diagnostics: PipelineDiagnostics
    let engine: ScriptedTranscriber
    let policy: ThermalPolicyTests.RecordingPolicy
    let session: TranscriptionSession
    let feed: AsyncStream<AudioEvent>
    let input: AsyncStream<AudioEvent>.Continuation
    let box: ThermalPolicyTests.Collected
    let healthBox: ThermalPolicyTests.HealthCollected
    let listener: Broadcast<TranscriptEvent>.Listener
    let health: Broadcast<HealthEvent>.Listener

    static func make() async -> MidSessionHeatFixture {
        let provider = ScriptedThermalProvider(initial: .fair)
        let diagnostics = PipelineDiagnostics(thermal: provider)
        let engine = ScriptedTranscriber.batch(runs: 3)
        let policy = ThermalPolicyTests.RecordingPolicy(delegate: ConservativeThermalPolicy())
        let session = TranscriptionSession(
            engine: engine, diagnostics: diagnostics, thermalPolicy: policy)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        return MidSessionHeatFixture(
            provider: provider, diagnostics: diagnostics, engine: engine, policy: policy,
            session: session, feed: feed, input: handle!,
            box: ThermalPolicyTests.Collected(),
            healthBox: ThermalPolicyTests.HealthCollected(),
            listener: await session.listen(), health: diagnostics.health())
    }
}
