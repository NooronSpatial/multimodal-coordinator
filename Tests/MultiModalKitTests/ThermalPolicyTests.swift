import Testing
import MultiModalKit
import MultiModalKitTesting
import Synchronization

/// RED SUITE for D-028 (SPEC §26–28, AC-54…AC-58): the thermal policy.
///
/// One question, one moment: when a whole-utterance run would move to the
/// settling table, the injected policy may refuse — the run retires, the
/// loss is loud (a named failure + a health event), and the live turn is
/// never touched. `nil` policy = the pipeline as it was, byte for byte.
@Suite(.timeLimit(.minutes(1)))
struct ThermalPolicyTests {

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

    actor HealthCollected {
        private(set) var events: [HealthEvent] = []
        func append(_ event: HealthEvent) { events.append(event) }
    }

    /// A policy under the test's thumb: fixed or delegated verdict, every
    /// consultation recorded — tests assert against the record, not hope.
    final class RecordingPolicy: ThermalPolicy, @unchecked Sendable {
        private let calls = Mutex<[(ThermalState, Int)]>([])
        private let verdict: @Sendable (ThermalState, Int) -> Bool

        init(allow: Bool) { self.verdict = { _, _ in allow } }
        init(delegate: any ThermalPolicy) {
            self.verdict = { delegate.allowSettlingDecode(thermal: $0, activeSettlingDecodes: $1) }
        }

        var recorded: [(ThermalState, Int)] { calls.withLock { $0 } }

        func allowSettlingDecode(thermal: ThermalState, activeSettlingDecodes: Int) -> Bool {
            calls.withLock { $0.append((thermal, activeSettlingDecodes)) }
            return verdict(thermal, activeSettlingDecodes)
        }
    }

    /// A whole-utterance engine whose FIRST run is defiant (`.silent`:
    /// ignores cancel, stream stays open, `forceFinal` can push a ghost) —
    /// the proof duty for the ticket door on the refusal path.
    static func batchWithDefiantFirstRun() -> ScriptedTranscriber {
        ScriptedTranscriber(
            plans: [.silent, .batch(manualRelease: true)],
            capabilities: EngineCapabilities(
                emitsPartials: false, wantsWholeUtterance: true, requiredSampleRate: 16_000))
    }

    // MARK: - AC-57: the shipped default's truth table (pure, no pipeline)

    @Test("ConservativeThermalPolicy: allow below .serious, refuse from .serious up")
    func conservativeDefaultTruthTable() {
        let policy = ConservativeThermalPolicy()
        #expect(policy.allowSettlingDecode(thermal: .nominal, activeSettlingDecodes: 0))
        #expect(policy.allowSettlingDecode(thermal: .fair, activeSettlingDecodes: 3))
        #expect(!policy.allowSettlingDecode(thermal: .serious, activeSettlingDecodes: 0))
        #expect(!policy.allowSettlingDecode(thermal: .critical, activeSettlingDecodes: 1))
    }

    // MARK: - AC-55 + AC-56: the refusal path, end to end

    @Test("At .serious the default policy refuses the settling move: named failure, health event, no ghost final")
    func refusalAtSeriousIsLoudAndExact() async {
        let provider = ScriptedThermalProvider(initial: .serious)
        let diagnostics = PipelineDiagnostics(thermal: provider)
        // Run 0 is DEFIANT: it ignores cancel and can be forced to answer
        // late — so the "no ghost final" assertion below tests the session's
        // ticket door, not the mock's good manners (review finding, 08-12).
        let engine = Self.batchWithDefiantFirstRun()
        let session = TranscriptionSession(
            engine: engine, diagnostics: diagnostics,
            thermalPolicy: ConservativeThermalPolicy())
        var handle: AsyncStream<AudioEvent>.Continuation!
        let feed = AsyncStream<AudioEvent> { handle = $0 }
        let input = handle!
        let box = Collected()
        let healthBox = HealthCollected()
        let listener = await session.listen()
        let health = diagnostics.health()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.run(events: feed) }
            group.addTask { for await event in listener.events { await box.append(event) } }
            group.addTask { for await event in health.events { await healthBox.append(event) } }

            // Utterance 0: one chunk, then it ends — the "decode" begins.
            input.yield(.speechStarted(utterance: 0, at: Self.t(0)))
            input.yield(.audioSegment(Self.chunk(at: 0)))
            input.yield(.speechEnded(at: Self.t(960)))
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true },
                    "utterance 0 never settled")

            // Utterance 1 begins on a HOT device — the policy must refuse
            // the settling move and retire run 0 instead.
            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { await box.events.count >= 1 },
                    "no refusal surfaced — D-028 not wired")
            #expect(await Self.until { engine.record(ofRun: 0)?.cancelled == true },
                    "the refused run was never cancelled")

            // The dead decode DEFIES the cancel and answers anyway — a real
            // ghost final enters the merge; the ticket door must drop it.
            engine.forceFinal(run: 0, text: "ghost")

            // Utterance 1 itself is LIVE work: it completes untouched.
            input.yield(.audioSegment(Self.chunk(at: 9600)))
            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { engine.record(ofRun: 1)?.audioFinished == true })
            engine.releaseFinal(run: 1)
            #expect(await Self.until { await box.events.count >= 2 },
                    "utterance 1's own final never arrived")

            input.finish()
            await session.stop()
            diagnostics.stop()
        }

        #expect(await box.events == [
            .failed(.declinedUnderThermalPressure, utterance: 0, at: Self.t(960)),
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(10560))
        ], "a refusal is one named failure; the ghost final must never surface")

        let healthEvents = await healthBox.events
        let refusals = healthEvents.filter {
            $0 == .settlingDecodeRefused(utterance: 0, thermal: .serious)
        }
        #expect(refusals.count == 1,
                "EXACTLY one health event per refusal (AC-56), got \(refusals.count)")
        #expect(!healthEvents.contains(.settlingDecodes(count: 1)),
                "a refused decode must never enter the settling count")
    }

    // MARK: - AC-54: nil policy = the pipeline as it was

    @Test("With no policy, a settling decode at .serious survives exactly as D-024 ruled")
    func nilPolicyChangesNothingEvenWhenHot() async {
        let provider = ScriptedThermalProvider(initial: .serious)
        let diagnostics = PipelineDiagnostics(thermal: provider)
        let engine = ScriptedTranscriber.batch(runs: 2)
        let session = TranscriptionSession(engine: engine, diagnostics: diagnostics)
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

            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            input.yield(.audioSegment(Self.chunk(at: 9600)))
            #expect(await Self.until { (engine.record(ofRun: 1)?.fedChunks.count ?? 0) >= 1 })

            engine.releaseFinal(run: 0)     // the late final SURVIVES: no policy, no refusal
            #expect(await Self.until { await box.events.count >= 1 },
                    "nil policy must keep D-024 behavior")

            input.yield(.speechEnded(at: Self.t(10560)))
            #expect(await Self.until { engine.record(ofRun: 1)?.audioFinished == true })
            engine.releaseFinal(run: 1)
            #expect(await Self.until { await box.events.count >= 2 })

            input.finish()
            await session.stop()
            diagnostics.stop()
        }

        #expect(await box.events == [
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960)),
            .final("u1:final(1 chunks)", utterance: 1, at: Self.t(10560))
        ])
    }

    // MARK: - AC-55: the policy sees exact inputs, at the one moment

    @Test("The policy is consulted once, at the settling move, with the exact thermal state and count")
    func policyReceivesExactInputs() async {
        let provider = ScriptedThermalProvider(initial: .fair)
        let diagnostics = PipelineDiagnostics(thermal: provider)
        let engine = ScriptedTranscriber.batch(runs: 2)
        let policy = RecordingPolicy(allow: true)
        let session = TranscriptionSession(
            engine: engine, diagnostics: diagnostics, thermalPolicy: policy)
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

            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { !policy.recorded.isEmpty },
                    "the policy was never consulted — D-028 not wired")

            engine.releaseFinal(run: 0)     // allowed → the late final survives
            #expect(await Self.until { await box.events.count >= 1 })

            input.finish()
            await session.stop()
            diagnostics.stop()
        }

        let calls = policy.recorded
        #expect(calls.count == 1, "exactly one consultation per settling move")
        #expect(calls.first ?? (.critical, -1) == (.fair, 0),
                "the policy must see the provider's state and the current settling count")
        #expect(await box.events.contains(
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960))),
            "an ALLOWED settling decode behaves exactly like D-024")
    }

    // MARK: - AC-55: the live turn is immune, even at .critical

    @Test("At .critical the ACTIVE utterance still settles and its final surfaces — only overlap is gated")
    func liveTurnIsImmuneAtCritical() async {
        let provider = ScriptedThermalProvider(initial: .critical)
        let diagnostics = PipelineDiagnostics(thermal: provider)
        let engine = ScriptedTranscriber.batch(runs: 1)
        let session = TranscriptionSession(
            engine: engine, diagnostics: diagnostics,
            thermalPolicy: ConservativeThermalPolicy())
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
            #expect(await Self.until { engine.record(ofRun: 0)?.audioFinished == true },
                    "the live utterance must settle even at .critical")

            engine.releaseFinal(run: 0)
            #expect(await Self.until { await box.events.count >= 1 },
                    "the live utterance's final must surface even at .critical")

            input.finish()
            await session.stop()
            diagnostics.stop()
        }

        #expect(await box.events == [
            .final("u0:final(1 chunks)", utterance: 0, at: Self.t(960))
        ], "no policy may ever gate the live turn (AC-55)")
    }

    // MARK: - the seam without diagnostics: policy still consulted, thermal reads .nominal

    @Test("Without diagnostics the policy still rules (thermal = .nominal) and a refusal still surfaces")
    func policyWorksWithoutDiagnostics() async {
        let engine = ScriptedTranscriber.batch(runs: 2)
        let policy = RecordingPolicy(allow: false)      // e.g. a concurrency cap
        let session = TranscriptionSession(engine: engine, thermalPolicy: policy)
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

            input.yield(.speechStarted(utterance: 1, at: Self.t(9600)))
            #expect(await Self.until { await box.events.count >= 1 },
                    "a refusal must not depend on diagnostics being injected")

            input.finish()
            await session.stop()
        }

        #expect(policy.recorded.count == 1)
        #expect(policy.recorded.first ?? (.critical, -1) == (.nominal, 0),
                "without diagnostics the policy sees .nominal — the default is then dormant by construction")
        #expect(await box.events == [
            .failed(.declinedUnderThermalPressure, utterance: 0, at: Self.t(960))
        ])
    }
}
