import AVFAudio
import Foundation
import MultiModalKit
import Synchronization
import Testing

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

/// THE NEURAL FAILURE PATH, PINNED (SPEC AC-109, D-053).
///
/// This file is a debt being paid. The 4e adversarial review found that a
/// failed decode reported its terminal, handed the player node back to the
/// engine, and then **kept going** — popping the next phrase and calling
/// `play()` on a node with no engine, which AVFoundation aborts the process
/// on rather than throwing. The fix (`retire()`) shipped GREEN-ONLY,
/// because `NeuralVoiceRun` held a concrete `TTSKit` and nothing can make a
/// 1.1 GB CoreML model fail on command. D-051 recorded that as a departure
/// from this repo's rule. `TTSDecoding` is what closes it.
///
/// **No model. No speaker. No environment gate.** Every test here runs on
/// every machine, which is the entire point: a guarantee that only holds
/// where the weights are installed is not pinned, it is hoped for.
///
/// ## Why every scripted step hands back an EMPTY sample array
///
/// Not tidiness — a MEASUREMENT (D-054). `SpyPlaybackHost` starts no
/// engine, so `bakeoff graph-probe` was written first to ask what a player
/// node off a running engine tolerates:
///
/// | probe case | verb | verdict |
/// |---|---|---|
/// | 1–3 | `stop()`, `reset()` | survives |
/// | 6 | `play()` | **aborts** — `_engine != nil` |
/// | 7 | `scheduleBuffer` | **aborts** — `_outputFormat.channelCount` |
///
/// `NeuralVoiceRun.render` returns early on empty samples, so an empty
/// step never reaches either aborting verb, while `cancel()` and
/// `teardown()` — which only `stop()`, `reset()` and detach — are safe.
/// That is why `ScriptedDecoder` has no way to emit a non-empty sample:
/// the type makes the rule unbreakable instead of asking a reader to
/// remember it. Anything that genuinely RENDERS stays where it already is
/// — `NeuralVoiceConformanceTests`, model-gated and `MMK_LIVE_SYNTH`-gated.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct NeuralVoiceFailurePathTests {

    // MARK: - helpers, in the house style

    static func until(_ condition: () async -> Bool, within: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    static func drain(_ run: any SynthesisRun) async -> [SynthesisUpdate] {
        var collected: [SynthesisUpdate] = []
        for await update in run.updates { collected.append(update) }
        return collected
    }

    static func makeRun(_ decoder: ScriptedDecoder,
                        _ host: SpyPlaybackHost) throws -> NeuralVoiceRun {
        // `.zero` lead: the cushion is `PlaybackLead`'s business and has its
        // own pure tests. Nothing here is about when playback starts.
        try NeuralVoiceRun(decoder: decoder, host: host, lead: PlaybackLead(target: .zero))
    }

    // MARK: - AC-109

    /// Fact 1. A decode that throws becomes exactly one `.failed`, and the
    /// stream ENDS — `drain` returning at all is that proof.
    @Test("a throwing decode reports failed once, terminal, and ends the stream")
    func aThrowingDecodeReportsFailedOnce() async throws {
        let decoder = ScriptedDecoder([.throwsAtOnce("the decoder blew up")])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        await run.feed("One. ")

        let updates = await Self.drain(run)
        #expect(updates == [.failed("neural voice: the decoder blew up")],
                "one terminal, carrying the decoder's own reason")
        #expect(decoder.threw)
    }

    /// Fact 2 — **THE ONE THAT EARNS THE SEAM.**
    ///
    /// A single `feed` puts TWO phrases in the queue in one locked step
    /// ("One. Two. Three." cuts to `One.` and ` Two.`, with ` Three.`
    /// still buffered). The first decode throws. Nothing behind it may be
    /// decoded, because the drain loop re-reads only the `cancelled` flag —
    /// and before `retire()` latched that flag on a terminal, the loop
    /// popped the next phrase and rendered it onto a node whose engine had
    /// already been handed back. In production that is not a wrong number:
    /// it is `probe case 6`, a process abort.
    @Test("a terminal RETIRES the run: a phrase queued behind the failure is never decoded")
    func aTerminalRetiresTheRun() async throws {
        let decoder = ScriptedDecoder([.throwsAtOnce("first phrase failed")])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        await run.feed("One. Two. Three.")

        let updates = await Self.drain(run)
        #expect(decoder.decodedTexts == ["One."],
                "the queue must be emptied by the terminal, not walked through it")
        #expect(updates == [.failed("neural voice: first phrase failed")],
                "and exactly one terminal, not one per queued phrase")
        // The node goes back exactly once, and nothing holds it afterwards.
        #expect(await Self.until { host.liveNodeCount == 0 })
        #expect(host.attachCount == 1)
    }

    /// Fact 3. An unspeakable phrase is never handed to the decoder AT ALL,
    /// and the reply still terminates.
    ///
    /// This is AC-106's guard, and until now it could only be tested with
    /// the model installed. The bug it prevents is not theoretical: a
    /// phrase containing nothing gives this model no reason to stop, so it
    /// decodes toward its 245-step cap — **19.6 seconds of audio for a
    /// phrase containing nothing** — and the turn loop waits inline for
    /// every one of them.
    @Test("an unspeakable phrase is never decoded, and the reply still finishes")
    func anUnspeakablePhraseIsNeverDecoded() async throws {
        let decoder = ScriptedDecoder([])          // nothing scripted: any
        let host = SpyPlaybackHost()               // decode at all would
        let run = try Self.makeRun(decoder, host)  // succeed, and be visible

        await run.feed(String(repeating: " ", count: 200))
        await run.feed("   ...   ")
        await run.finishTokens()

        let updates = await Self.drain(run)
        #expect(updates.last == .finished, "an unspeakable reply must still end")
        #expect(decoder.decodedTexts.isEmpty,
                "nothing speakable, so nothing decoded — the 245-step cap is never approached")
        #expect(decoder.stepsTaken == 0)
    }

    /// Fact 4. `cancel()` mid-decode reaches the decoder through its OWN
    /// channel: the step callback answers `false`.
    ///
    /// Event-gated at both ends — the cancel waits for the decode to have
    /// actually started, and the assertion waits for the decoder to report
    /// that it was stopped. No sleeps, and the decoder's spin cap means a
    /// stop that never arrives fails as an assertion rather than a hang.
    @Test("cancel during a decode stops it through the decode's own channel")
    func cancelDuringADecodeStopsIt() async throws {
        let decoder = ScriptedDecoder([.stepsUntilStopped])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        await run.feed("A sentence long enough to still be decoding. ")
        #expect(await Self.until { decoder.callCount == 1 },
                "the decode must be running before the cancel means anything")

        await run.cancel()

        #expect(await Self.until { decoder.wasStopped },
                "the run's callback must answer false once the ticket is dead")
        #expect(!decoder.capExhausted, "the stop must arrive, not be waited out")
        let updates = await Self.drain(run)
        #expect(updates.isEmpty, "a cancelled reply reports no terminal — the seam's contract")
    }

    /// Fact 5, **with its limit stated rather than implied.**
    ///
    /// The production guard is `if live { report(.failed…) }` in the catch
    /// arm: a decode that throws after a cancel must stay silent. What this
    /// test proves is that the throw HAPPENS and no terminal is observed.
    /// What it CANNOT prove is the guard itself — `cancel()` has already
    /// finished the stream, so a late `.failed` would be dropped by the
    /// stream whether the guard exists or not. The guard's remaining value
    /// is the second `teardown()` it avoids, and this suite does not pin
    /// that: asserting "a detach never happens later" would need a timing
    /// guess, which this repo does not allow. Said here instead of left for
    /// a reader to assume.
    @Test("a decode that throws after a cancel reports nothing")
    func aThrowAfterACancelIsSilent() async throws {
        let decoder = ScriptedDecoder([.stepsUntilStoppedThenThrows("too late to matter")])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        await run.feed("A sentence that will fail after it is cancelled. ")
        #expect(await Self.until { decoder.callCount == 1 })

        await run.cancel()

        #expect(await Self.until { decoder.threw }, "the decode must really have failed")
        #expect(!decoder.capExhausted, "the stop must arrive, not be waited out")
        let updates = await Self.drain(run)
        #expect(!updates.contains { if case .failed = $0 { true } else { false } })
    }

    /// A HOST THAT CANNOT RENDER IS A NAMED FAILURE, not silence.
    ///
    /// `PlaybackHost` throws `.notRendering` rather than attaching a node to
    /// a graph nobody pulls, because a silent attach leaves the caller
    /// waiting forever for audio that will never play — a hang that once
    /// cost twenty minutes of a measurement run (INSTRUMENTS §14). The
    /// promise is tested at the host level; this pins that the RUN
    /// propagates it instead of returning a run that can never speak.
    @Test("a host that refuses to render makes the run fail loudly at construction")
    func aRefusingHostFailsLoudly() async throws {
        let decoder = ScriptedDecoder([])
        let host = SpyPlaybackHost(refusing: true)

        #expect(throws: PlaybackHostFailure.notRendering) {
            _ = try Self.makeRun(decoder, host)
        }
        #expect(decoder.decodedTexts.isEmpty, "and nothing was decoded on the way there")
    }

    // MARK: - what the seam also made testable

    /// THE BARGE PROMISE, WITHOUT THE MODEL.
    ///
    /// `feed` must hand off, never decode. The suite that owns this promise
    /// needs the real model, and says so: *"a mock that returns instantly
    /// cannot fail it."* True — but a mock that never returns can. A
    /// decoder still stepping when the cancel arrives fails this test on
    /// any machine, which is strictly better than a promise that only holds
    /// where 1.1 GB of weights are installed.
    ///
    /// The fault it guards is the one the FIELD found before the suite
    /// did: `feed` used to `await` a whole phrase decode, on the
    /// coordinator's one serial loop, so the speech onset meant to cancel
    /// the reply queued behind the decode of the reply it was stopping.
    @Test("feed hands off rather than decoding — no model needed")
    func feedHandsOffRatherThanDecoding() async throws {
        let decoder = ScriptedDecoder([.stepsUntilStopped])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        // If `feed` awaited the decode, this line would not be reached
        // until the decoder's spin cap ran out — and the cap is what turns
        // that into a fast failure instead of a hang.
        await run.feed("This is a deliberately long sentence, "
                       + "long enough that decoding all of it takes real work. ")
        await run.cancel()

        let updates = await Self.drain(run)
        #expect(!updates.contains(.started),
                "a reply cancelled this early was never audible")
        #expect(!updates.contains(.finished),
                "a cancelled reply must not claim completion")
        #expect(!decoder.capExhausted)
    }

    /// THE RUN RENDERS AT ITS DECODER'S RATE, asked rather than assumed.
    ///
    /// The rate used to arrive as a second constructor argument beside the
    /// decoder — always `Double(kit.sampleRate)`, from the single call
    /// site. Two ways to state one fact is how a 24 kHz voice gets played
    /// as 16 kHz, which is precisely what the field reported as a voice
    /// "speaking in weird way like someone drunk". The host's own graph
    /// runs at 48 kHz here, so a run that quietly adopted the host's rate
    /// would be caught too.
    @Test("the run's render format comes from the decoder, not from the host")
    func theFormatComesFromTheDecoder() async throws {
        let decoder = ScriptedDecoder([], sampleRate: 24_000)
        let host = SpyPlaybackHost()
        _ = try Self.makeRun(decoder, host)

        #expect(host.formatRates == [24_000])
    }

    /// D-052's public verb, which shipped with ZERO callers and no test.
    ///
    /// The ownership rule itself is proven at the host level
    /// (`PlaybackHostTests`). This pins the promise `shutdown()`'s own
    /// documentation makes and nothing checked: *safe to call more than
    /// once, and safe to call on a voice that never spoke.* No model
    /// required — a voice that never spoke never loaded one.
    @Test("shutdown is safe on a voice that never spoke, and safe twice")
    func shutdownIsSafeOnASilentVoice() async {
        let voice = NeuralVoice()
        await voice.shutdown()
        await voice.shutdown()
    }

    // MARK: - AC-181 (4p): the one-shot decoder's limit

    /// **A LIMIT, PINNED — not a bug being fixed.**
    ///
    /// Kokoro is StyleTTS 2: not autoregressive, so it produces a whole
    /// phrase at once. Fact 4 proves the cancel channel works when there
    /// is a next step to skip. Here there is none, and this test says so
    /// out loud: the callback answers `false`, the step happens anyway,
    /// and **the compute is not saved**. That is the entire cost of a
    /// one-shot decoder, and it is a cost, never a correctness hole —
    /// because the ticket, not the callback, is the guarantee.
    ///
    /// The ordering is a fact, not a race: the decode parks until
    /// `release()`, the test cancels FIRST, and only then releases. So
    /// "the stop arrived while the decode was in flight" is guaranteed
    /// rather than hoped for.
    @Test("a one-shot decode cannot be stopped in flight, and still publishes nothing")
    func aOneShotDecodeCannotBeStoppedInFlight() async throws {
        let decoder = ScriptedDecoder([.oneShotWhenReleased])
        let host = SpyPlaybackHost()
        let run = try Self.makeRun(decoder, host)

        await run.feed("A sentence this model renders in one piece. ")
        #expect(await Self.until { decoder.callCount == 1 },
                "the decode must be in flight before the cancel means anything")

        await run.cancel()
        decoder.release()          // only now may the single step land

        #expect(await Self.until { decoder.stepsTaken == 1 },
                "the step happens ANYWAY — the buffer existed before anyone could ask it to stop")
        #expect(decoder.wasStopped,
                "the run did answer false; it simply arrived too late to save any work")
        #expect(!decoder.capExhausted, "the release must arrive, not be waited out")

        let updates = await Self.drain(run)
        #expect(updates.isEmpty,
                "and nothing reaches the app: a cancelled reply reports no terminal")
        #expect(await Self.until { host.liveNodeCount == 0 },
                "the node goes back even on the one-shot path")
    }
}
#endif
