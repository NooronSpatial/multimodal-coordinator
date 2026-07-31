import MultiModalKit
import Testing

/// SPEC AC-11 — the loudness judge, pure and exact.
@Suite(.timeLimit(.minutes(1))) struct EnergyVADTests {

    /// A chunk of `count` frames, all at the same absolute level.
    private func chunk(_ level: Float, count: Int = 100) -> [Float] {
        [Float](repeating: level, count: count)
    }

    private var config: EnergyVAD.Config {
        EnergyVAD.Config(threshold: 0.02, hangoverFrames: 300)
    }

    @Test func silenceProducesNothing() {
        var vad = EnergyVAD(config: config)
        #expect(vad.process(chunk(0.001)) == nil)
        #expect(vad.process(chunk(0.0)) == nil)
    }

    @Test func firstLoudChunkStartsSpeech() {
        var vad = EnergyVAD(config: config)
        #expect(vad.process(chunk(0.5)) == .speechStarted)
        #expect(vad.process(chunk(0.5)) == nil)          // still speaking: no repeat
    }

    @Test func exactThresholdCountsAsLoud() {
        var vad = EnergyVAD(config: config)
        #expect(vad.process(chunk(0.02)) == .speechStarted)   // >= threshold, not >
    }

    @Test func shortGapInsideHangoverKeepsSpeaking() {
        var vad = EnergyVAD(config: config)
        _ = vad.process(chunk(0.5))
        #expect(vad.process(chunk(0.0, count: 299)) == nil)   // 299 < 300: inside the budget
        #expect(vad.process(chunk(0.5)) == nil)               // still speaking, no new start
    }

    @Test func hangoverBoundaryIsExact() {
        var vad = EnergyVAD(config: config)
        _ = vad.process(chunk(0.5))
        #expect(vad.process(chunk(0.0, count: 299)) == nil)   // budget: 299 of 300 spent
        #expect(vad.process(chunk(0.0, count: 1)) == .speechEnded)  // frame 300 ends it
    }

    @Test func loudChunkResetsTheHangoverBudget() {
        var vad = EnergyVAD(config: config)
        _ = vad.process(chunk(0.5))
        _ = vad.process(chunk(0.0, count: 299))               // almost over…
        _ = vad.process(chunk(0.5))                            // …but speech returns
        #expect(vad.process(chunk(0.0, count: 299)) == nil)   // fresh budget: 299 again OK
        #expect(vad.process(chunk(0.0, count: 1)) == .speechEnded)
    }

    @Test func fullConversationSequence() {
        var vad = EnergyVAD(config: config)
        var transitions: [EnergyVAD.Transition] = []
        let script: [[Float]] = [
            chunk(0.0),                    // quiet
            chunk(0.5),                    // speech!
            chunk(0.4),                    // still speech
            chunk(0.0, count: 150),        // small gap…
            chunk(0.6),                    // …speech again (one utterance)
            chunk(0.0, count: 300),        // real silence: over
            chunk(0.7),                    // a second utterance
            chunk(0.0, count: 300),        // over again
        ]
        for c in script {
            if let t = vad.process(c) { transitions.append(t) }
        }
        #expect(transitions == [
            .speechStarted, .speechEnded,
            .speechStarted, .speechEnded,
        ])
    }

    @Test func emptyChunkIsIgnored() {
        var vad = EnergyVAD(config: config)
        _ = vad.process(chunk(0.5))
        #expect(vad.process([]) == nil)                       // no frames, no opinion
    }
}
