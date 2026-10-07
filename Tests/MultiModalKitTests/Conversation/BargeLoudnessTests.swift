// 5d PIECE 3 — THE ECHO: A BARGE PROVES ITSELF BY BEING LOUD (SPEC §242;
// F-38 A, F-39 A, F-40 A; the diet app's R-4).
//
//   onset ─▶ deadline (onset + window) ─▶ only a LOUD chunk at or after it cuts the reply
//   quiet chunks inside the hangover prove nothing — the verdict no longer
//   depends on the hangover, and every candidate is reported as it was judged
//
// Scripted audio events through the coordinator, on the audio timeline:
// 20 ms chunks at 48 kHz, each carrying the VAD's verdict. A loud chunk is
// RMS 0.5, a quiet one 0 — binary exact.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

/// What the coordinator reported about barges.
final class CandidateRecorder: LatencyReporter, Sendable {
    private let kept = Mutex<(candidates: [BargeCandidate], barges: [BargeTimeline])>(([], []))

    func turnLatency(_ duration: Duration, turn: Int) {}
    func cancelLatency(_ duration: Duration, turn: Int) {}
    func bargeTimeline(_ timeline: BargeTimeline) { kept.withLock { $0.barges.append(timeline) } }
    func bargeCandidate(_ candidate: BargeCandidate) { kept.withLock { $0.candidates.append(candidate) } }

    var candidates: [BargeCandidate] { kept.withLock { $0.candidates } }
    var barges: [BargeTimeline] { kept.withLock { $0.barges } }
}

@Suite("AC-355…AC-360 · a barge proves itself by being loud", .timeLimit(.minutes(1)))
struct BargeLoudnessTests {

    /// 48 kHz: 1 ms = 48 frames.
    static func ms(_ milliseconds: Int) -> Int { milliseconds * 48 }

    /// One 20 ms chunk at `milliseconds`, with the VAD's verdict on it
    /// (nil: the VAD said nothing — every chunk before piece 3).
    static func chunk(at milliseconds: Int, loud: Bool?) -> AudioEvent {
        .audioSegment(AudioChunk(samples: [Float](repeating: loud == false ? 0 : 0.5, count: 960),
                                 start: TurnCoordinatorTests.t(ms(milliseconds)), isLoud: loud))
    }

    /// Chunks every 20 ms over `[from, to)`.
    static func chunks(_ from: Int, _ to: Int, loud: Bool?) -> [AudioEvent] {
        stride(from: from, to: to, by: 20).map { chunk(at: $0, loud: loud) }
    }

    static func onset(_ milliseconds: Int) -> AudioEvent {
        .speechStarted(utterance: 1, at: TurnCoordinatorTests.t(ms(milliseconds)))
    }

    static func end(_ milliseconds: Int) -> AudioEvent {
        .speechEnded(at: TurnCoordinatorTests.t(ms(milliseconds)))
    }

    struct Outcome {
        let barged: Bool
        let recorder: CandidateRecorder
    }

    /// Drives a turn to SPEAKING, plays `events` over it, and says whether
    /// the reply was cut — bounded, so a red row fails instead of hanging.
    static func play(_ events: [AudioEvent], window: Duration = .milliseconds(320)) async throws -> Outcome {
        let recorder = CandidateRecorder()
        let bench = try TurnCoordinatorTests.Bench(
            generator: ScriptedReplyGenerator(plans: [.manual(ignoresCancel: true), .manual()]),
            synthesizer: ScriptedSynthesizer(plans: [.manual(ignoresCancel: true), .manual()]),
            clock: ContinuousClock(), reporter: recorder, config: .init(bargeWindow: window))
        let listener = await bench.coordinator.listen()
        var barged = false
        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)
            bench.speak(utterance: 0, final: "tell me a story", at: 0)
            _ = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
            bench.generator.emit(reply: 0, token: "Once")
            _ = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
            bench.synthesizer.reportStarted(utterance: 0)
            _ = await TurnCoordinatorTests.until { await bench.coordinator.currentState == .speaking }
            for event in events { bench.audio.yield(event) }
            barged = await TurnCoordinatorTests.until({
                await bench.coordinator.currentState == .listening
            }, within: .seconds(2))
            bench.finishInputs()
            await bench.coordinator.stop()
        }
        return Outcome(barged: barged, recorder: recorder)
    }

    // MARK: - AC-356: the diet app's numbers

    @Test("hangover 700 ms: a sound loud for 280 ms, then quiet, does NOT cut the reply (AC-356)")
    func theDietAppsLeakDoesNotCut() async throws {
        let outcome = try await Self.play([Self.onset(1000)]
            + Self.chunks(1000, 1280, loud: true) + Self.chunks(1280, 1980, loud: false) + [Self.end(1980)])
        #expect(!outcome.barged, "280 ms of loudness is a leak; 700 ms of hangover proves nothing")
        #expect(outcome.recorder.candidates == [BargeCandidate(
            turn: 0, window: .milliseconds(980), loudTime: .milliseconds(280), peak: 0.5, accepted: false)],
                "reported as judged: abandoned, loud for 280 ms (AC-360)")
    }

    // MARK: - AC-355: the hangover has no part in the verdict

    @Test("the same sound gives the same verdict at a 300 ms and a 700 ms hangover (AC-355)")
    func theHangoverHasNoPart() async throws {
        for hangover in [300, 700] {
            let short = try await Self.play([Self.onset(1000)] + Self.chunks(1000, 1280, loud: true)
                + Self.chunks(1280, 1280 + hangover, loud: false) + [Self.end(1280 + hangover)])
            #expect(!short.barged, "loud 280 ms, hangover \(hangover) ms: not a barge")
            let long = try await Self.play([Self.onset(1000)] + Self.chunks(1000, 1400, loud: true)
                + Self.chunks(1400, 1400 + hangover, loud: false) + [Self.end(1400 + hangover)])
            #expect(long.barged, "loud 400 ms, hangover \(hangover) ms: a barge")
            #expect(long.recorder.barges.map(\.window) == [.milliseconds(320)],
                    "cut at the first loud chunk ≥ deadline")
        }
    }

    // MARK: - AC-357: still loud at the deadline, even after a pause

    @Test("a person between two words — a pause across the deadline — cuts at the next LOUD chunk (AC-357)")
    func aPauseAcrossTheDeadline() async throws {
        let outcome = try await Self.play([Self.onset(1000)] + Self.chunks(1000, 1200, loud: true)
            + Self.chunks(1200, 1400, loud: false) + Self.chunks(1400, 1600, loud: true))
        #expect(outcome.barged)
        #expect(outcome.recorder.barges.map(\.window) == [.milliseconds(400)],
                "⑦ runs to the first LOUD chunk at or after the deadline — not to a quiet one at 320")
        #expect(outcome.recorder.candidates == [BargeCandidate(
            turn: 0, window: .milliseconds(400), loudTime: .milliseconds(220), peak: 0.5, accepted: true)],
                "reported as judged: accepted, 200 + 20 ms loud (AC-360)")
    }

    // MARK: - AC-359: what does not change

    @Test("a chunk the VAD said nothing about still counts as loud — the old rule, unchanged (AC-359)")
    func unknownIsLoud() async throws {
        let outcome = try await Self.play([Self.onset(1000)] + Self.chunks(1000, 1400, loud: nil))
        #expect(outcome.barged)
        #expect(outcome.recorder.barges.map(\.window) == [.milliseconds(320)])
    }

    // MARK: - F-39: the number, re-read in loud time

    @Test("the measured window is 320 ms of LOUD time (D-140, F-39 A)")
    func theMeasuredWindow() {
        #expect(BargeWindow.measured == .milliseconds(320))
    }

    // MARK: - AC-358: an abandoned candidate's words reach no prompt

    @Test("an abandoned candidate's words, arriving after the reply, never join the next prompt (AC-358)")
    func abandonedWordsStayOut() async throws {
        for wordsArriveAfterTheReply in [true, false] {
            let recorder = CandidateRecorder()
            let bench = try TurnCoordinatorTests.Bench(
                generator: .manual(replies: 2), synthesizer: .manual(utterances: 2),
                clock: ContinuousClock(), reporter: recorder, config: .init(bargeWindow: .milliseconds(320)))
            let listener = await bench.coordinator.listen()
            await withTaskGroup(of: Void.self) { group in
                bench.start(in: &group, listener: listener)
                bench.speak(utterance: 0, final: "say good morning", at: 0)
                _ = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 1 }
                bench.generator.emit(reply: 0, token: "Good morning!")
                _ = await TurnCoordinatorTests.until { bench.synthesizer.utterancesOpened == 1 }
                bench.synthesizer.reportStarted(utterance: 0)
                _ = await TurnCoordinatorTests.until { await bench.coordinator.currentState == .speaking }

                // The reply's own "Good morning!" leaks back for 100 ms — abandoned.
                for event in [Self.onset(1000)] + Self.chunks(1000, 1100, loud: true) + [Self.end(1400)] {
                    bench.audio.yield(event)
                }
                _ = await TurnCoordinatorTests.until { recorder.candidates.count == 1 }
                let leak = TranscriptEvent.final("Good morning.", utterance: 1,
                                                 at: TurnCoordinatorTests.t(Self.ms(1400)))
                if !wordsArriveAfterTheReply { bench.transcripts.yield(leak) }
                bench.generator.finish(reply: 0)
                // The voice can finish only once it was told the words are over
                // — the order every real mouth keeps (the bench's own warning).
                _ = await TurnCoordinatorTests.until {
                    bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true
                }
                bench.synthesizer.reportFinished(utterance: 0)
                _ = await TurnCoordinatorTests.until { await bench.box.events.contains(.turnCompleted(turn: 0)) }
                if wordsArriveAfterTheReply { bench.transcripts.yield(leak) }

                bench.speak(utterance: 2, final: "What's your name?", at: Self.ms(3000))
                // A `let`, not `#expect(await …until { … })`: written that way, this
                // row read reply 1's record as nil in BOTH cases although the
                // wait reported success — the wait had not waited. Not understood;
                // this form waits, and reads the record every time.
                let secondReplyOpened = await TurnCoordinatorTests.until { bench.generator.repliesOpened == 2 }
                #expect(secondReplyOpened, "the person's next question opens a reply")
                #expect(bench.generator.record(ofReply: 1)?.transcript == "What's your name?",
                        "the leak's words arrived \(wordsArriveAfterTheReply ? "after" : "during") the reply")
                bench.finishInputs()
                await bench.coordinator.stop()
            }
        }
    }
}
