import AVFAudio
import Foundation
import MultiModalKit
import Synchronization
import Testing

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

/// A LIVENESS HOLE, PINNED WHERE IT CAN BE SEEN (D-055, open).
///
/// Found by the adversarial review of the `TTSDecoding` seam, and then
/// MEASURED here rather than argued (D-054). It is **pre-existing** — the
/// seam did not cause it — and the seam is why it can now be reproduced at
/// all: making a decode finish on command, before the token stream closes,
/// needs an injectable decoder.
///
/// ## The hole
///
/// `PlaybackLead` banks audio before the first sound. Two places learn that
/// "the reply is complete, so the target will never be reached":
///
/// - `speak()`'s liveness step, which has a `.release` arm and calls
///   `releaseLead()`. Its own comment says why: *"If nothing released it
///   here, the player would never start, no buffer would ever report
///   played, `finished` would never fire, and the turn would hang."*
/// - `finishTokens()`, which has **no such arm**. Its last line is
///   `(phrasesInFlight == 0 && scheduled == played) ? .finishNow : .wait`,
///   and `.wait` does nothing.
///
/// So when the last phrase's decode has ALREADY completed and the token
/// stream closes afterwards, nobody releases the lead. Measured:
///
/// | lead target | `finishTokens` | started | finished |
/// |---|---|---|---|
/// | `.zero` (shipped today) | after the decode | true | true |
/// | 1500 ms | **after** the decode | **false** | **false** |
/// | 1500 ms | before the decode ends | true | true |
///
/// ## Why it is not biting today, and why that is temporary
///
/// `NeuralVoice.defaultLead` is `PlaybackLead.deficit(forReplyOf: 6s,
/// realTimeFactor: 0.752)`, and `deficit` returns `.zero` for any RTF at or
/// below 1.0 — so every caller in this repo runs with a zero lead, where
/// the first buffer starts the player and the hole cannot open.
///
/// **It opens the moment RTF exceeds 1.0**, because then the lead is
/// non-zero by arithmetic. That is a slower machine — and the iPhone's RTF
/// has never been measured, because AC-104 did not happen. A phone that
/// decodes slower than it plays, with a reply short enough to fit inside
/// the lead, hangs the turn. That is 4f's territory exactly.
///
/// ## Why case B asserts the BUG
///
/// Deliberately, and this is the only honest option that keeps CI green
/// without deleting the evidence. Asserting the hole means it cannot be
/// forgotten, and when D-055 is ruled and fixed, **case B's expectation
/// flips from `false` to `true` and this file becomes the fix's proof.**
/// A test that asserted the desired behaviour today would simply be red,
/// and a deleted probe would leave nothing but a paragraph.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct PlaybackLeadStrandTests {

    /// Emits REAL samples, unlike `NeuralVoiceFailurePathTests`'
    /// `ScriptedDecoder`, so it must ONLY ever be paired with a real engine:
    /// `play()` and `scheduleBuffer` abort the process on a node that is on
    /// no running engine (`bakeoff graph-probe`, cases 6 and 7). The samples
    /// are zeros, so a real engine renders silence.
    final class RenderingDecoder: TTSDecoding, @unchecked Sendable {
        let sampleRate = 24_000
        private let steps: Int
        private let perStep: Int
        private let done = Mutex(false)
        var finishedDecoding: Bool { done.withLock { $0 } }

        init(steps: Int, perStep: Int) { self.steps = steps; self.perStep = perStep }

        func decode(_ text: String, temperature: Float?,
                    onStep: @escaping @Sendable ([Float]) -> Bool) async throws {
            for _ in 0..<steps {
                guard onStep([Float](repeating: 0, count: perStep)) else { return }
                await Task.yield()
            }
            done.withLock { $0 = true }
        }
    }

    static func until(_ c: () async -> Bool, within: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while clock.now < deadline {
            if await c() { return true }
            await Task.yield()
        }
        return false
    }

    /// Collects updates until `.finished` arrives or the window closes.
    ///
    /// A BOUNDED drain, because the whole subject of this suite is a reply
    /// that never finishes — an unbounded `for await` would hang instead of
    /// reporting, and a red test must fail fast.
    static func drainBounded(_ run: any SynthesisRun,
                             within: Duration) async -> [SynthesisUpdate] {
        let box = Mutex<[SynthesisUpdate]>([])
        let collector = Task { for await u in run.updates { box.withLock { $0.append(u) } } }
        _ = await until({ box.withLock { $0.contains(.finished) } }, within: within)
        collector.cancel()
        return box.withLock { $0 }
    }

    /// Builds the run, or returns nil when this machine has no engine to
    /// render on — skipping honestly rather than failing for the wrong
    /// reason, the D-022 discipline.
    static func makeRun(_ decoder: RenderingDecoder,
                        lead: Duration) -> (NeuralVoiceRun, AudioEnginePlaybackHost)? {
        let host = AudioEnginePlaybackHost()
        guard let run = try? NeuralVoiceRun(decoder: decoder, host: host,
                                            lead: PlaybackLead(target: lead))
        else { return nil }
        return (run, host)
    }

    @Test("CONTROL — the shipped zero lead finishes even when tokens close after the decode")
    func zeroLeadFinishes() async throws {
        let decoder = RenderingDecoder(steps: 4, perStep: 2400)      // 400 ms of audio
        guard let (run, host) = Self.makeRun(decoder, lead: .zero) else { return }
        defer { host.stopRendering() }

        await run.feed("Yes. ")
        #expect(await Self.until { decoder.finishedDecoding })
        await run.finishTokens()

        let updates = await Self.drainBounded(run, within: .seconds(3))
        #expect(updates.contains(.started))
        #expect(updates.contains(.finished),
                "the configuration this library actually ships must never strand a reply")
    }

    @Test("THE HOLE (D-055) — a lead larger than the reply strands it when tokens close last")
    func nonZeroLeadStrandsWhenTokensCloseAfterTheDecode() async throws {
        let decoder = RenderingDecoder(steps: 4, perStep: 2400)      // 400 ms << 1500 ms
        guard let (run, host) = Self.makeRun(decoder, lead: .milliseconds(1500))
        else { return }
        defer { host.stopRendering() }

        await run.feed("Yes. ")
        // GATE ON THE ACCOUNTING, NOT ON THE DECODER. The decoder reports
        // done from inside `decode`, which is BEFORE `speak()`'s liveness
        // step has run — closing the token stream in that window lets
        // `speak()`'s own `.release` arm save the reply, and the hole never
        // opens. Waiting on the decoder flaked 3 times in 20 for exactly
        // that reason. `phrasesInFlight` returning to 0 is the fact that the
        // accounting has happened; `scheduled > 0` proves audio was really
        // queued; `!tokensFinished` proves this is the ordering under test.
        #expect(await Self.until {
            let c = run.counters
            return c.phrasesInFlight == 0 && c.scheduled > 0 && !c.tokensFinished
        }, "the last decode must be accounted for while the token stream is still open")
        #expect(run.counters.played == 0, "and nothing can have played, since nothing started")

        await run.finishTokens()

        let updates = await Self.drainBounded(run, within: .seconds(2))
        // ASSERTING THE BUG, ON PURPOSE. See this suite's note: when D-055
        // is ruled and fixed, both of these flip to `#expect(contains)` and
        // this test becomes the proof of the fix.
        #expect(!updates.contains(.started),
                "TODAY: nothing releases the lead, so the player never starts")
        #expect(!updates.contains(.finished),
                "TODAY: and therefore the turn would hang — this is D-055, open")
        await run.cancel()
    }

    @Test("THE CONTRAST — the same lead is fine when the token stream closes first")
    func nonZeroLeadIsFineWhenTokensCloseFirst() async throws {
        let decoder = RenderingDecoder(steps: 4, perStep: 2400)
        guard let (run, host) = Self.makeRun(decoder, lead: .milliseconds(1500))
        else { return }
        defer { host.stopRendering() }

        await run.feed("Yes. ")
        await run.finishTokens()          // closes FIRST, so speak()'s arm runs

        let updates = await Self.drainBounded(run, within: .seconds(3))
        #expect(updates.contains(.started),
                "speak()'s own `.release` arm covers this ordering")
        #expect(updates.contains(.finished))
        await run.cancel()
    }
}
#endif
