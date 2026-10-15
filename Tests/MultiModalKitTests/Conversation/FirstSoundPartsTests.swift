// 5d PIECE 5 — ⑤ IN ITS PARTS (SPEC §257–§262, D-146, F-48 A).
//
//   the first token ─(a) words─▶ the first decode asked for ─(b) decode─▶ its first audio ─(c) rest─▶ SOUND
//
// The voice measures (a) and (b) where they happen; the coordinator, which
// stamps the first token and the first sound, carries them in the timeline,
// and (c) is what is left — so (a) + (b) + (c) = ⑤ by construction.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing
@testable import MultiModalKitTTS

@Suite("AC-373 · the first sound in its parts", .timeLimit(.minutes(1)), .serialized)
struct FirstSoundPartsTests {

    /// One turn, no gate, on the manual clock: the first sound 300 ms after
    /// the first token, the voice reporting `parts` (or nothing).
    static func timeline(voiceReports parts: FirstSoundParts?) async throws -> TurnTimeline? {
        let clock = ManualClock()
        let recorder = EarlyRecorder()
        let bench = try TurnCoordinatorTests.Bench(
            generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
            clock: clock, reporter: recorder)
        let listener = await bench.coordinator.listen()
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "say something", at: 0)
            let opened = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            #expect(opened)
            bench.generator.emit(reply: 0, token: "Hello.")
            let mouth = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            #expect(mouth)
            if let parts { bench.synthesizer.setFirstSoundParts(parts, utterance: 0) }
            await clock.advance(by: .milliseconds(300))
            bench.synthesizer.reportStarted(utterance: 0)
            let reported = await TurnCoordinatorTests.until { !recorder.timelines.isEmpty }
            #expect(reported)
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        return recorder.timelines.first
    }

    @Test("the voice's parts reach the timeline, and the rest is what is left of ⑤")
    func thePartsReachTheTimeline() async throws {
        let parts = FirstSoundParts(words: .milliseconds(100), decode: .milliseconds(150))
        let timeline = try #require(try await Self.timeline(voiceReports: parts))
        #expect(timeline.firstSound == .milliseconds(300))
        #expect(timeline.firstSoundParts == parts, "(a) and (b), as the voice measured them")
        #expect(timeline.firstSoundRest == .milliseconds(50), "(c) = ⑤ − (a) − (b)")
    }

    @Test("a voice that says nothing keeps a single ⑤")
    func aSilentVoice() async throws {
        let timeline = try #require(try await Self.timeline(voiceReports: nil))
        #expect(timeline.firstSound == .milliseconds(300))
        #expect(timeline.firstSoundParts == nil)
        #expect(timeline.firstSoundRest == nil)
    }

    /// The neural voice measures them from stamps it already keeps: its
    /// birth (the first token), the first decode asked for, its first audio.
    @Test("the neural voice reports the wait for its first phrase and that phrase's decode")
    func theNeuralVoiceMeasures() async throws {
        let decoder = ScriptedDecoder([.stepsProducing([2400, 4800])], sampleRate: 24_000)
        // A REAL host: real samples on a spy host's node would throw (see
        // `DecodeStepRecordTests`); skipped honestly where there is none.
        let host = AudioEnginePlaybackHost()
        defer { host.stopRendering() }
        // birth · +30 ms until the decode is asked for (the words) · +50 ms of
        // decoding to the first audio · then the rest.
        let time = DecodeStepRecordTests.ScriptedTime([.zero, .milliseconds(30), .milliseconds(50),
                                                       .milliseconds(100)])
        guard let run = try? NeuralVoiceRun(decoder: decoder, host: host,
                                            lead: PlaybackLead(target: .zero),
                                            now: time.now) else { return }
        await run.feed("Two steps. ")
        let measured = await DecodeStepRecordTests.until { run.firstSoundParts != nil }
        #expect(measured, "the first audio is out: the parts are known")
        #expect(run.firstSoundParts == FirstSoundParts(words: .milliseconds(30), decode: .milliseconds(50)))
        await run.cancel()
    }
}
