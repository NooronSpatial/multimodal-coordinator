import Testing
import MultiModalKit
import MultiModalKitTesting

/// `ThermalPolicyTests`, continued. Topic: AC-55's negative space — the
/// retirements that are NOT settling moves, where the policy is never asked.
extension ThermalPolicyTests {

    // MARK: - AC-55's negative space: where the policy must NEVER be asked

    @Test("A streaming engine's barge-in retirement never consults the policy")
    func streamingEnginesNeverConsultThePolicy() async {
        let engine = ScriptedTranscriber(plans: [
            .normal(partialEveryChunks: 1), .normal(partialEveryChunks: 1)
        ])
        let policy = RecordingPolicy(allow: false)      // would refuse, if asked
        let session = TranscriptionSession(engine: engine, thermalPolicy: policy)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            // Utterance 0 is barged mid-speech — D-021 strict retirement.
            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            #expect(await Self.until { await box.events.count >= 1 })   // its partial

            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { engine.record(ofRun: 0)?.cancelled == true },
                    "streaming retirement must still cancel")

            input.yield(.audioSegment(Self.chunk(at: 9600)))
            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { await box.events.contains {
                if case .final(_, 1, _) = $0 { return true } else { return false }
            } })

            input.finish()
            await session.stop()
        }

        #expect(policy.recorded.isEmpty,
                "the policy gates BATCH overlap only — streaming retirement is not its business")
    }

    @Test("Barging a batch utterance that never settled retires it silently — no consultation, no failure event")
    func unsettledBatchBargeIsNotAPolicyMatter() async {
        let engine = ScriptedTranscriber.batch(runs: 2)
        let policy = RecordingPolicy(allow: false)
        let session = TranscriptionSession(engine: engine, thermalPolicy: policy)
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let listener = await session.listen()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }

            // Utterance 0: speech begins and is barged BEFORE any speechEnded
            // — old.settling is false, so this is live-turn replacement
            // (D-021), not a settling move. The policy has no say.
            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            #expect(await Self.until { (engine.record(ofRun: 0)?.fedChunks.count ?? 0) >= 1 })

            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { engine.record(ofRun: 0)?.cancelled == true },
                    "an unsettled batch run is retired like a streaming one")

            input.yield(.audioSegment(Self.chunk(at: 9600)))
            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { engine.record(ofRun: 1)?.audioFinished == true })
            engine.releaseFinal(run: 1)
            #expect(await Self.until { await box.events.count >= 1 })

            input.finish()
            await session.stop()
        }

        #expect(policy.recorded.isEmpty, "no consultation outside the settling move (AC-55)")
        #expect(await box.events == [
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(10560))
        ], "an unsettled barge is silent retirement — no declined failure, ever")
    }
}
