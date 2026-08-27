import Testing
import MultiModalKit
import MultiModalKitTesting

/// THE ENGINE CONFORMANCE KIT (SPEC AC-36, D-017).
///
/// One set of promises every `TranscriptionEngine` must keep — scripted today,
/// Apple's tomorrow, a Whisper module after that. "We can switch engines" is
/// proven here, by tests, not promised in a README.
///
/// The kit knows nothing about any engine's insides: it feeds audio through
/// the public seam and asserts only the contract.
enum EngineConformanceKit {

    static func chunk(at frames: Int) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: 0.5, count: 960),
                   start: AudioTime(frames: frames, sampleRate: 48_000))
    }

    /// Collects a run's updates until its stream ends (spin-capped by the
    /// suite's time limit; conformant engines end their streams).
    static func drain(_ run: any TranscriptionRun) async -> [TranscriptionUpdate] {
        var updates: [TranscriptionUpdate] = []
        for await update in run.updates { updates.append(update) }
        return updates
    }

    /// Promise 1: a fed-and-finished run emits AT MOST ONE final, nothing
    /// after it, and its stream ends.
    static func verifyOneFinalAndTermination(_ engine: any TranscriptionEngine) async throws {
        let run = try await engine.openRun(format: AudioStreamFormat())
        await run.feed(chunk(at: 0))
        await run.feed(chunk(at: 960))
        await run.finishAudio()

        let updates = await drain(run)
        let finals = updates.filter { if case .final = $0 { true } else { false } }
        #expect(finals.count == 1, "a finished run must settle on exactly one final")
        if case .final = updates.last {} else {
            Issue.record("the final must be the LAST update — something spoke after it")
        }
    }

    /// Promise 2: partials, if the engine claims them, come before the final
    /// and never after it.
    static func verifyPartialsRespectTheFinal(_ engine: any TranscriptionEngine) async throws {
        let run = try await engine.openRun(format: AudioStreamFormat())
        for chunkIndex in 0..<6 { await run.feed(chunk(at: chunkIndex * 960)) }
        await run.finishAudio()

        let updates = await drain(run)
        guard case .final = updates.last else {
            Issue.record("no final at the end of a finished run")
            return
        }
        if engine.capabilities.emitsPartials {
            let partials = updates.dropLast().allSatisfy {
                if case .partial = $0 { true } else { false }
            }
            #expect(partials, "everything before the final must be a partial")
        }
    }

    /// Promise 3: a cancelled run ends its stream WITHOUT a final.
    static func verifyCancelEndsWithoutAFinal(_ engine: any TranscriptionEngine) async throws {
        let run = try await engine.openRun(format: AudioStreamFormat())
        await run.feed(chunk(at: 0))
        await run.cancel()

        let updates = await drain(run)
        let finals = updates.filter { if case .final = $0 { true } else { false } }
        #expect(finals.isEmpty, "a cancelled run must not settle on a final")
    }
}

/// The kit, applied to the scripted engine in its CONFORMANT plans.
/// (The `.silent` plan violates promise 3 on purpose — it is the ticket's
/// sparring partner, not a conformant engine, and is deliberately absent.)
@Suite(.timeLimit(.minutes(1)))
struct ScriptedTranscriberConformanceTests {
    @Test("one final, then silence, then the stream ends")
    func oneFinal() async throws {
        try await EngineConformanceKit.verifyOneFinalAndTermination(
            ScriptedTranscriber(plans: [.normal(partialEveryChunks: 2)]))
    }

    @Test("partials come before the final, never after")
    func partialsBeforeFinal() async throws {
        try await EngineConformanceKit.verifyPartialsRespectTheFinal(
            ScriptedTranscriber(plans: [.normal(partialEveryChunks: 2)]))
    }

    @Test("cancel ends the stream without a final")
    func cancelWithoutFinal() async throws {
        try await EngineConformanceKit.verifyCancelEndsWithoutAFinal(
            ScriptedTranscriber(plans: [.normal(partialEveryChunks: 2)]))
    }
}

/// The kit, applied to APPLE's engine — gated on the model being installed,
/// so CI (which has no model) skips it silently instead of lying.
///
/// Honest scope: without recorded speech, only the cancel promise can be
/// verified here — an engine fed constant samples may legitimately produce
/// no final at all. Promises 1 and 2 are exercised against real speech by
/// the demo apps, on real hardware, and the README says so.
@Suite(.timeLimit(.minutes(2)))
struct AppleSpeechEngineConformanceTests {
    @Test("cancel ends the stream without a final (model required; skips if absent)")
    func cancelWithoutFinal() async throws {
        let engine = AppleSpeechEngine()
        guard await engine.modelInstalled() else { return }   // nothing to verify here
        try await EngineConformanceKit.verifyCancelEndsWithoutAFinal(engine)
    }
}

#if canImport(MultiModalKitWhisper)
import MultiModalKitWhisper

/// The kit, applied to the WHISPER engine — gated on the model being on disk
/// (WhisperKit's hub folder), so CI skips honestly. On a machine with the
/// model this runs the real CoreML pipeline: expect seconds, not
/// milliseconds — first inference compiles the graphs.
@Suite(.timeLimit(.minutes(4)), .serialized)
struct WhisperEngineConformanceTests {
    @Test("one final, then silence, then the stream ends (model required; skips if absent)")
    func oneFinal() async throws {
        let engine = WhisperEngine()
        guard await engine.modelInstalled() else { return }
        try await EngineConformanceKit.verifyOneFinalAndTermination(engine)
    }

    @Test("cancel ends the stream without a final (model required; skips if absent)")
    func cancelWithoutFinal() async throws {
        let engine = WhisperEngine()
        guard await engine.modelInstalled() else { return }
        try await EngineConformanceKit.verifyCancelEndsWithoutAFinal(engine)
    }

    @Test("prewarm is safe and idempotent (model required; skips if absent)")
    func prewarmIsSafeAndIdempotent() async throws {
        let engine = WhisperEngine()
        engine.prewarm()
        guard await engine.modelInstalled() else { return }
        try await engine.ensureModel()
        engine.prewarm()
    }
}
#endif
