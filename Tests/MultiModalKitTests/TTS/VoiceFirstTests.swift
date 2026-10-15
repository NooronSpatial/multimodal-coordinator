// 5d PIECE 5's FIX — THE VOICE TAKES THE FLOOR (SPEC §265, D-148: F-51 A; AC-379).
//
// The voice takes the floor for its FIRST phrase's decode only, and gives it
// back when that decode is done — its audio out, or a failure, or a cancel.

import MultiModalKit
import Synchronization
import Testing
@testable import MultiModalKitTTS

/// A decoder that notes, at the start of each decode, whether the floor is taken.
final class FloorWitnessDecoder: TTSDecoding, @unchecked Sendable {
    let inner: ScriptedDecoder
    let floor: VoiceFloor
    private let seen = Mutex<[Bool]>([])
    var sampleRate: Int { inner.sampleRate }
    var takenAtEachDecode: [Bool] { seen.withLock { $0 } }

    init(_ inner: ScriptedDecoder, floor: VoiceFloor) {
        self.inner = inner
        self.floor = floor
    }

    func decode(_ text: String, temperature: Float?,
                onStep: @escaping @Sendable ([Float]) -> Bool) async throws {
        seen.withLock { $0.append(floor.isTaken) }
        try await inner.decode(text, temperature: temperature, onStep: onStep)
    }
}

@Suite("AC-379 · the voice takes the floor for its first phrase", .timeLimit(.minutes(1)), .serialized)
struct VoiceFirstTests {

    static func run(_ decoder: FloorWitnessDecoder) throws -> NeuralVoiceRun {
        try NeuralVoiceRun(decoder: decoder, host: SpyPlaybackHost(),
                           lead: PlaybackLead(target: .zero), floor: decoder.floor)
    }

    @Test("the first phrase decodes with the floor taken; the second does not; then it is free")
    func firstPhraseOnly() async throws {
        let floor = VoiceFloor()
        let decoder = FloorWitnessDecoder(ScriptedDecoder([.steps(1), .steps(1)]), floor: floor)
        let run = try Self.run(decoder)
        await run.feed("One. Two. ")
        await run.finishTokens()
        let both = await DecodeStepRecordTests.until { decoder.inner.callCount == 2 }
        #expect(both)
        #expect(decoder.takenAtEachDecode == [true, false], "F-51 A: the first phrase only")
        let free = await DecodeStepRecordTests.until { !floor.isTaken }
        #expect(free, "given back once the first decode is done")
        await run.cancel()
    }

    @Test("a first decode that fails gives the floor back")
    func aFailureGivesItBack() async throws {
        let floor = VoiceFloor()
        let decoder = FloorWitnessDecoder(ScriptedDecoder([.throwsAtOnce("no voice today")]), floor: floor)
        let run = try Self.run(decoder)
        await run.feed("One. ")
        let decoded = await DecodeStepRecordTests.until { decoder.inner.callCount == 1 }
        #expect(decoded)
        #expect(decoder.takenAtEachDecode == [true])
        let free = await DecodeStepRecordTests.until { !floor.isTaken }
        #expect(free, "a failed decode must not leave the mind waiting")
        await run.cancel()
    }

    @Test("a voice given no floor decodes as before")
    func noFloor() async throws {
        let decoder = ScriptedDecoder([.steps(1)])
        let run = try NeuralVoiceRun(decoder: decoder, host: SpyPlaybackHost(), lead: PlaybackLead(target: .zero))
        await run.feed("One. ")
        let decoded = await DecodeStepRecordTests.until { decoder.callCount == 1 }
        #expect(decoded)
        await run.cancel()
    }
}
