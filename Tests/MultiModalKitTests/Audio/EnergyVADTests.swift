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
        // Float lesson: 0.02 has no exact binary form — its RMS rounds a hair
        // below itself. 0.25 is a power of two, so 0.25² = 0.0625, mean and
        // square root stay EXACT, and rms == threshold is truly testable.
        var vad = EnergyVAD(config: .init(threshold: 0.25, hangoverFrames: 300))
        #expect(vad.process(chunk(0.25)) == .speechStarted)   // >= threshold, not >
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
            chunk(0.0, count: 300)        // over again
        ]
        for audioChunk in script {
            if let transition = vad.process(audioChunk) { transitions.append(transition) }
        }
        #expect(transitions == [
            .speechStarted, .speechEnded,
            .speechStarted, .speechEnded
        ])
    }

    @Test func emptyChunkIsIgnored() {
        var vad = EnergyVAD(config: config)
        _ = vad.process(chunk(0.5))
        #expect(vad.process([]) == nil)                       // no frames, no opinion
    }

    // MARK: - 1d: the onset window (AC-73…AC-75, AC-77, D-035)

    /// The window used below: 300 loud frames must persist before a start.
    private var debounced: EnergyVAD.Config {
        EnergyVAD.Config(threshold: 0.25, hangoverFrames: 300, onsetFrames: 300)
    }

    @Test func subWindowBurstProducesNothingEver() {
        // AC-73, the flap killer: a burst shorter than the window is not
        // speech — no start, and therefore never an end either.
        var vad = EnergyVAD(config: debounced)
        #expect(vad.process(chunk(0.5, count: 299)) == nil)   // one frame short
        for _ in 0..<10 {
            #expect(vad.process(chunk(0.0)) == nil)           // quiet forever after:
        }                                                     // nothing was ever open
    }

    @Test func onsetBoundaryIsExact() {
        // AC-75: the window fires on the frame that completes it — the same
        // exact-boundary arithmetic the hangover proves on its side.
        var vad = EnergyVAD(config: debounced)
        #expect(vad.process(chunk(0.5, count: 299)) == nil)   // 299 of 300
        #expect(vad.process(chunk(0.5, count: 1)) == .speechStarted)  // frame 300
    }

    @Test func oneBigChunkCompletesTheWindowAlone() {
        // A single chunk carrying the whole window starts speech at once.
        var vad = EnergyVAD(config: debounced)
        #expect(vad.process(chunk(0.5, count: 300)) == .speechStarted)
    }

    @Test func quietKillsTheCandidate() {
        // AC-75, F-2 = A: one quiet chunk resets the count — loud runs
        // never accumulate across a gap.
        var vad = EnergyVAD(config: debounced)
        #expect(vad.process(chunk(0.5, count: 299)) == nil)   // almost…
        #expect(vad.process(chunk(0.0, count: 1)) == nil)     // …the candidate dies
        #expect(vad.process(chunk(0.5, count: 299)) == nil)   // fresh count, not 598
        #expect(vad.process(chunk(0.5, count: 1)) == .speechStarted)
    }

    @Test func defaultWindowIsZeroAndOff() {
        // AC-74: the default Config carries no window; the first loud chunk
        // fires exactly as before 1d. (The untouched pre-1d suite above is
        // the byte-for-byte proof; this pins the default itself.)
        #expect(EnergyVAD.Config().onsetFrames == 0)
        var vad = EnergyVAD(config: .init(threshold: 0.25, hangoverFrames: 300))
        #expect(vad.process(chunk(0.5, count: 1)) == .speechStarted)
    }

    @Test func hangoverIsUntouchedByTheWindow() {
        // AC-77: the window guards only the quiet→speaking door. While
        // speaking, loudness still resets the quiet budget as before —
        // even a sub-window loud chunk, because it is not an onset.
        var vad = EnergyVAD(config: debounced)
        _ = vad.process(chunk(0.5, count: 300))               // started
        #expect(vad.process(chunk(0.0, count: 299)) == nil)   // budget almost spent
        #expect(vad.process(chunk(0.5, count: 100)) == nil)   // 100 < 300: still resets it
        #expect(vad.process(chunk(0.0, count: 299)) == nil)   // fresh budget again
        #expect(vad.process(chunk(0.0, count: 1)) == .speechEnded)
        #expect(vad.process(chunk(0.5, count: 100)) == nil)   // AC-73 applies again:
        #expect(vad.process(chunk(0.0, count: 300)) == nil)   // a click reopens nothing
    }

    @Test func fullSequenceWithTransientsAroundARealWord() {
        // The field scenario from 5be72ac, in miniature: click · word · click.
        var vad = EnergyVAD(config: debounced)
        var transitions: [EnergyVAD.Transition] = []
        let script: [[Float]] = [
            chunk(0.5, count: 100),        // the metronome tick — sub-window
            chunk(0.0, count: 100),        // (kills the candidate)
            chunk(0.5, count: 300),        // a real word: the whole window
            chunk(0.0, count: 300),        // real silence: over
            chunk(0.5, count: 100),        // another tick
            chunk(0.0, count: 300)        // quiet
        ]
        for audioChunk in script {
            if let transition = vad.process(audioChunk) { transitions.append(transition) }
        }
        #expect(transitions == [.speechStarted, .speechEnded])
    }
}
