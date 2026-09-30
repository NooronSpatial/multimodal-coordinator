// 5d PIECE 1 — THE PAUSES INSIDE AN ANSWER (SPEC §225/2; F-27 A, AC-341).
//
//   sound  ███░░░░░░░░░███░░░░░███████░░░░░░░░░░░
//             └ 400 ms ┘   └200┘          └ the tail: never counted
//
// The meter is pure: a scripted stream with KNOWN silences in, exact
// counts out. 16 kHz, so every stretch is a whole number of frames and
// every duration below is exact (1 ms = 16 frames).

import MultiModalKit
import Testing

@Suite("AC-341 · the pauses inside an answer")
struct SilenceMeterTests {

    static let rate = 16_000.0

    static func sound(_ milliseconds: Int, level: Float = 0.5) -> [Float] {
        Array(repeating: level, count: milliseconds * 16)
    }
    static func silence(_ milliseconds: Int) -> [Float] {
        Array(repeating: 0, count: milliseconds * 16)
    }
    static func meter() -> SilenceMeter { SilenceMeter(config: .init(sampleRate: rate)) }

    @Test("a pause longer than the gap counts; a shorter one does not; the longest is kept")
    func countsTheLongPauses() {
        var meter = Self.meter()
        meter.feed(Self.sound(100) + Self.silence(400) + Self.sound(100)
                   + Self.silence(200) + Self.sound(100))
        #expect(meter.gaps == 1, "400 ms counts, 200 ms does not")
        #expect(meter.longest == .milliseconds(400))
    }

    @Test("the silence before the first sound and after the last is not a pause inside the answer")
    func edgesAreNotPauses() {
        var meter = Self.meter()
        meter.feed(Self.silence(300) + Self.sound(100) + Self.silence(500))
        #expect(meter.gaps == 0)
        #expect(meter.longest == .zero)
    }

    @Test("a pause split across buffers is ONE pause")
    func pausesSpanBuffers() {
        let stream = Self.sound(100) + Self.silence(400) + Self.sound(100)
            + Self.silence(350) + Self.sound(100)
        var meter = Self.meter()
        var start = 0
        while start < stream.count {                // 777 frames at a time: no buffer edge is a stretch's edge
            let end = min(start + 777, stream.count)
            meter.feed(stream[start..<end])
            start = end
        }
        #expect(meter.gaps == 2)
        #expect(meter.longest == .milliseconds(400))
    }

    @Test("exactly the gap counts")
    func theBoundaryCounts() {
        var meter = Self.meter()
        meter.feed(Self.sound(100) + Self.silence(300) + Self.sound(100))
        #expect(meter.gaps == 1, "300 ms is at least 300 ms")
    }

    @Test("quiet is not silence: a soft stretch above the level is sound")
    func quietIsNotSilence() {
        var meter = Self.meter()
        meter.feed(Self.sound(100) + Self.sound(500, level: 0.002) + Self.sound(100))
        #expect(meter.gaps == 0)
        #expect(meter.longest == .zero)
    }
}
