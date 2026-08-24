import Foundation
import MultiModalKit
import Synchronization
import Testing
import TTSKit

@testable import MultiModalKitTTS

/// D-070 — A RETIRED VOICE IS TERMINAL, and these tests check the
/// CONSEQUENCE rather than the call.
///
/// AC-145 already claimed this and was satisfied by a load counter: the
/// counter proved `retire()` was CALLED. The review proved the thing that
/// mattered was still open — the retired voice would happily build a second
/// 1.1 GB pipeline on its next use, which is the 2.2 GB jetsam kill
/// `retire()` was written to prevent (INSTRUMENTS §28/§29).
///
/// So: no counter of calls here. Every test asks what the voice DOES
/// afterwards.
@Suite("a retired voice is terminal")
struct RetiredVoiceIsTerminalTests {

    /// The consequence, without needing a 1.1 GB model: a retired voice must
    /// REFUSE, and refusing is observable with no weights on disk because the
    /// refusal happens before anything is loaded.
    /// THROWING IS NOT THE POINT — NOT REACHING FOR THE MODELS IS.
    ///
    /// The first version of this test asserted only that it threw, and it
    /// passed with the guard deleted: the post-await re-check caught it
    /// anyway, ninety-six seconds and one full 1.1 GB load later. Same
    /// visible outcome, opposite consequence, and the consequence is the
    /// whole reason `retire()` exists. So the assertion is the load count.
    @Test("a retired voice refuses to open an utterance WITHOUT reaching for the models")
    func retiredVoiceRefusesToOpen() async throws {
        let voice = VoiceLevers(decoder: .stepped).makeVoice()
        await voice.retire()
        await #expect(throws: (any Error).self) {
            _ = try await voice.openUtterance()
        }
        #expect(await voice.loadAttempts == 0,
                "a retired voice that LOADS before refusing is the 2.2 GB kill")
    }

    @Test("a retired voice refuses ensureModel without loading either")
    func retiredVoiceRefusesEnsure() async throws {
        let voice = VoiceLevers(decoder: .stepped).makeVoice()
        await voice.retire()
        await #expect(throws: (any Error).self) {
            try await voice.ensureModel()
        }
        #expect(await voice.loadAttempts == 0)
    }

    @Test("retiring twice is safe, and the second changes nothing")
    func retireIsIdempotent() async throws {
        let voice = VoiceLevers(decoder: .stepped).makeVoice()
        await voice.retire()
        await voice.retire()
        #expect(await voice.isRetired)
    }

    @Test("a voice that was never retired still opens (the eyes control)")
    func liveVoiceIsNotRefused() async throws {
        // Without this, "refuses" is indistinguishable from "always throws".
        // Gated on the model, because opening really does load.
        let voice = VoiceLevers(decoder: .fused).makeVoice()
        guard await voice.modelInstalled() else { return }
        let run = try await voice.openUtterance()
        #expect(await voice.loadAttempts == 1,
                "and a LIVE voice does reach — otherwise zero proves nothing")
        await run.cancel()
        await voice.retire()
    }

    /// THE BLOCKER'S OWN TEST. A speaking run keeps itself alive through its
    /// drain task, so retiring the voice must reach INTO the run and cancel
    /// it — otherwise the pipeline is not freed and the comment in
    /// `settleLevers` is a wish.
    @Test("retiring a speaking voice cancels the reply in flight (model + MMK_LIVE_SYNTH=1)")
    func retireCancelsTheLiveRun() async throws {
        guard ProcessInfo.processInfo.environment["MMK_LIVE_SYNTH"] == "1" else { return }
        let voice = VoiceLevers(decoder: .fused).makeVoice()
        guard await voice.modelInstalled() else { return }

        let run = try await voice.openUtterance()
        let ended = Mutex(false)
        let reader = Task {
            for await _ in run.updates {}
            ended.withLock { $0 = true }
        }
        await run.feed("The audio travels through a ring buffer into a pump.")
        await voice.retire()          // must reach the run

        // BOUNDED, because the regression is a HANG. Removing the cancel
        // from `retire()` leaves the run draining forever, and `await
        // reader.value` waited for it forever — the mutation that proved
        // this test load-bearing produced no output at all instead of a red
        // line. CLAUDE.md §3.3: a red test fails fast or it is not a test.
        // A wall-clock deadline is allowed here and nowhere near the
        // deterministic suites: this one is gated on real audio and a real
        // 1.1 GB model, so there is no injected clock to reach for.
        let deadline = ContinuousClock().now + .seconds(10)
        while !ended.withLock({ $0 }), ContinuousClock().now < deadline {
            await Task.yield()
        }
        reader.cancel()
        #expect(ended.withLock { $0 },
                "the stream must end — a retired voice cannot leave a run draining")
    }
}
