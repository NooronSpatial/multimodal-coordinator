import Testing
import MultiModalKit
import Foundation

/// THE SYNTHESIS CONFORMANCE KIT (SPEC AC-80, the D-017 pattern one seam
/// over): the promises every self-speaking `SynthesisRun` must keep —
/// Apple's mouth today, a neural one later. "We can switch mouths" is
/// proven here, not promised.
///
/// Scope, honestly: the kit fits mouths that SPEAK ON THEIR OWN. The
/// scripted synthesizer is test-driven by design (its updates are the
/// test's to emit), so the kit does not apply to it — its conformance is
/// exercised all over the coordinator suite.
enum SynthesizerConformanceKit {

    static func drain(_ run: any SynthesisRun) async -> [SynthesisUpdate] {
        var collected: [SynthesisUpdate] = []
        for await update in run.updates { collected.append(update) }
        return collected
    }

    /// Promise 1: a fed-and-finished reply reports `started` once, then
    /// `finished` once, in that order, and the stream ends.
    static func verifyStartedThenFinished(_ synthesizer: any SpeechSynthesizing) async throws {
        let run = try await synthesizer.openUtterance()
        await run.feed("One.")
        await run.feed(" Two.")
        await run.finishTokens()

        let updates = await drain(run)
        #expect(updates.first == .started, "sound must be reported before anything else")
        #expect(updates.last == .finished, "the reply ends when the room is quiet")
        #expect(updates.filter { $0 == .started }.count == 1)
        #expect(updates.filter { $0 == .finished }.count == 1)
    }

    /// Promise 2: a cancelled reply ends its stream WITHOUT a terminal.
    static func verifyCancelEndsWithoutATerminal(_ synthesizer: any SpeechSynthesizing) async throws {
        let run = try await synthesizer.openUtterance()
        await run.feed("This sentence is about to be interrupted mid-way.")
        await run.cancel()

        let updates = await drain(run)
        #expect(!updates.contains(.finished), "a cancelled reply must not claim completion")
    }

    /// Promise 3: a reply with nothing worth saying completes silently —
    /// `finished` arrives, `started` never does. (No audio is touched:
    /// this promise holds anywhere, CI included.)
    static func verifySilentReplyCompletesWithoutSpeaking(
        _ synthesizer: any SpeechSynthesizing
    ) async throws {
        let run = try await synthesizer.openUtterance()
        await run.feed("   ")
        await run.finishTokens()

        let updates = await drain(run)
        #expect(updates == [.finished], "nothing to say: finished, and no started ever")
    }

    /// Promise 4 — THE LIVENESS PROMISE: a reply always terminates. Every
    /// piece the mouth accepts must eventually be accounted for, so the
    /// coordinator can never be stranded mid-turn waiting for a `finished`
    /// that will not come. The adversarial input is a long unbroken run of
    /// whitespace: it is big enough to force the phraser's max-length cut,
    /// so a naive mouth queues a piece with NOTHING SPEAKABLE in it — and
    /// if the platform declines to report on an unspeakable utterance, the
    /// count never balances and the turn hangs forever.
    static func verifyUnspeakableContentStillTerminates(
        _ synthesizer: any SpeechSynthesizing
    ) async throws {
        let run = try await synthesizer.openUtterance()
        await run.feed(String(repeating: " ", count: 200))
        await run.feed("   ...   ")
        await run.finishTokens()

        let updates = await drain(run)      // hangs here if the count leaks
        #expect(updates.last == .finished, "an unspeakable reply must still end")
    }
}

/// The kit, applied to APPLE's mouth. Promise 3 is deterministic and runs
/// everywhere. Promises 1 and 2 make the machine SPEAK — real audio, real
/// delegate timing — and a headless runner's behavior there is not ours
/// to assume (the D-022 discipline: what touches hardware is verified on
/// hardware). They are gated on an explicit opt-in switch; a machine with
/// a human at it runs:  MMK_LIVE_SYNTH=1 swift test
/// CI without the switch skips them honestly, exactly like the
/// model-gated engine suites.
@Suite(.timeLimit(.minutes(2)), .serialized)
struct AppleSynthesizerConformanceTests {
    static var liveAudioAllowed: Bool {
        ProcessInfo.processInfo.environment["MMK_LIVE_SYNTH"] == "1"
    }

    @Test("a silent reply completes without speaking (runs everywhere)")
    func silentReply() async throws {
        try await SynthesizerConformanceKit.verifySilentReplyCompletesWithoutSpeaking(
            AppleSpeechSynthesizer())
    }

    @Test("started once, finished once, in order (live audio; MMK_LIVE_SYNTH=1 to run)")
    func startedThenFinished() async throws {
        guard Self.liveAudioAllowed else { return }    // hardware-only, honestly skipped
        try await SynthesizerConformanceKit.verifyStartedThenFinished(AppleSpeechSynthesizer())
    }

    @Test("cancel silences and ends without a terminal (live audio; MMK_LIVE_SYNTH=1 to run)")
    func cancelWithoutTerminal() async throws {
        guard Self.liveAudioAllowed else { return }
        try await SynthesizerConformanceKit.verifyCancelEndsWithoutATerminal(AppleSpeechSynthesizer())
    }

    @Test("an unspeakable reply still terminates — the liveness promise (runs everywhere)")
    func unspeakableStillTerminates() async throws {
        try await SynthesizerConformanceKit.verifyUnspeakableContentStillTerminates(
            AppleSpeechSynthesizer())
    }
}
