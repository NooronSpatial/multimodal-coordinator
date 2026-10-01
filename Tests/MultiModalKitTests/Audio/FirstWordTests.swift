// 5d PIECE 2 — THE FIRST WORD, MEASURED (SPEC §235/3; F-35 A, AC-351).
//
//   player starts ─▶ ░░░░░░░░░░░░[ the first word …
//   (⑤ is stamped here)  └ the quiet the person still waits through ┘
//
// Kokoro starts every phrase with ~325 ms of its own quiet, so the first
// sound is stamped well before the first word (INSTRUMENTS §73b). The meter
// measures that quiet from what is actually played; the listening host's
// ear publishes it per reply. 16 kHz, so every duration is exact.

import AVFAudio
@testable import MultiModalKit
import Testing

@Suite("AC-351 · the first word, measured")
struct FirstWordTests {

    static let rate = 16_000.0

    static func sound(_ milliseconds: Int) -> [Float] { Array(repeating: 0.5, count: milliseconds * 16) }
    static func quiet(_ milliseconds: Int) -> [Float] { Array(repeating: 0.0004, count: milliseconds * 16) }
    static func meter() -> SilenceMeter { SilenceMeter(config: .init(sampleRate: rate)) }

    @Test("the quiet before the first sound is measured, exactly")
    func theLeadingQuiet() {
        var meter = Self.meter()
        meter.feed(Self.quiet(325) + Self.sound(100) + Self.quiet(420))
        #expect(meter.leading == .milliseconds(325))
    }

    @Test("split across buffers, it is the same quiet")
    func acrossBuffers() {
        let stream = Self.quiet(325) + Self.sound(100)
        var meter = Self.meter()
        var start = 0
        while start < stream.count {                  // 777 frames at a time
            let end = min(start + 777, stream.count)
            meter.feed(stream[start..<end])
            start = end
        }
        #expect(meter.leading == .milliseconds(325))
    }

    @Test("a reply that never sounds has no first word")
    func noSoundNoFirstWord() {
        var meter = Self.meter()
        meter.feed(Self.quiet(800))
        #expect(meter.leading == nil)
    }

    @Test("sound at once: no quiet before it")
    func soundAtOnce() {
        var meter = Self.meter()
        meter.feed(Self.sound(100))
        #expect(meter.leading == .zero)
    }

    @Test("the quiet before the first word is not a pause inside the answer")
    func notAGap() {
        var meter = Self.meter()
        meter.feed(Self.quiet(500) + Self.sound(100))
        #expect(meter.gaps == 0)
        #expect(meter.longest == .zero)
        #expect(meter.leading == .milliseconds(500))
    }

    /// One buffer of `samples`, as a player node renders it.
    static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    @Test("the host's ear publishes each reply's quiet before its first word")
    func theEarPublishesIt() throws {
        let ear = ReplyEar(meter: Self.meter())
        try ear.hear(Self.buffer(Self.quiet(200)))
        try ear.hear(Self.buffer(Self.quiet(125) + Self.sound(100)))
        try ear.hear(Self.buffer(Self.quiet(420)))
        #expect(ear.pauses.leadingQuiet == .milliseconds(325))
    }

    /// Found by the Mac harness (runs 7 and 8): a tap on a player node hears
    /// the node's silent buffers from the moment it is attached — before
    /// `play()`, while the first phrase is still being synthesized — and the
    /// ear counted that wait, which is ⑤, as the reply's own quiet.
    @Test("buffers rendered before the player starts are not the reply's quiet")
    func beforeThePlayerStarts() throws {
        let ear = ReplyEar(meter: Self.meter())
        try ear.hear(Self.buffer(Array(repeating: 0, count: 16 * 120)), playerFrame: nil)    // decoding, not yet playing
        try ear.hear(Self.buffer(Array(repeating: 0, count: 16 * 150)), playerFrame: nil)
        try ear.hear(Self.buffer(Self.quiet(40) + Self.sound(100)), playerFrame: 0)
        #expect(ear.pauses.leadingQuiet == .milliseconds(40), "only what the PLAYER held before its first word")
    }

    /// The second half of the harness's lesson (runs 9 and 10): a tap's block
    /// runs a buffer or two AFTER the render, so "is it playing now?" let
    /// silent buffers from before the start through. The player's own sample
    /// position says exactly which frames came before its start.
    @Test("a buffer that straddles the player's start counts only from the start")
    func aBufferStraddlingTheStart() throws {
        let ear = ReplyEar(meter: Self.meter())
        let beforeStart = Array(repeating: Float(0), count: 16 * 120)
        try ear.hear(Self.buffer(beforeStart + Self.quiet(40) + Self.sound(100)), playerFrame: -Int64(16 * 120))
        #expect(ear.pauses.leadingQuiet == .milliseconds(40))
    }

    @Test("a reply cut before it ever sounded publishes no first word")
    func aSilentReplyPublishesNone() throws {
        let ear = ReplyEar(meter: Self.meter())
        try ear.hear(Self.buffer(Self.quiet(300)))
        #expect(ear.pauses.leadingQuiet == nil)
    }
}
