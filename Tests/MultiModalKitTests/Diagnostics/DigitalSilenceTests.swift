import Testing
import MultiModalKitBench

/// 4o — AC-178's metric, pinned before it is trusted with a verdict.
///
/// The session's FIRST dropout metric was an amplitude threshold, and the
/// review proved it an artifact that produced a confident false
/// conclusion. This one has no threshold to be wrong about — a player
/// that runs dry renders exact zeros, and speech never is — but "no
/// threshold" is not the same as "no bugs", so it gets tests.
///
/// 1000 samples per second throughout: every millisecond is one sample,
/// so the expected values are whole numbers and binary-exact.
@Suite("digital silence is measured, not estimated")
struct DigitalSilenceTests {

    static func measure(_ samples: [Float], minimumRun: Double = 20)
        -> DigitalSilence.Report {
        DigitalSilence.measure(samples: samples, sampleRate: 1000,
                               minimumRunMilliseconds: minimumRun)
    }

    @Test("continuous speech has no dropouts")
    func continuousSpeechIsClean() {
        let report = Self.measure([Float](repeating: 0.5, count: 1000))
        #expect(report.runs == 0)
        #expect(report.totalMilliseconds == 0)
        #expect(report.spanMilliseconds == 1000)
        #expect(report.millisecondsPerSecond == 0)
    }

    /// LEADING AND TRAILING SILENCE ARE NOT DROPOUTS, and this is the
    /// test that keeps the metric honest about the very thing it
    /// measures: a bigger cushion means MORE leading silence, so a metric
    /// that counted it would report the cure as the disease.
    @Test("the cushion's own silence is not counted against it")
    func leadingAndTrailingSilenceIgnored() {
        var samples = [Float](repeating: 0, count: 3000)      // 3 s of lead
        samples += [Float](repeating: 0.5, count: 500)
        samples += [Float](repeating: 0, count: 2000)         // and a tail
        let report = Self.measure(samples)
        #expect(report.runs == 0)
        #expect(report.spanMilliseconds == 500)
    }

    @Test("a gap inside the speech is found, with its length")
    func oneInternalGap() {
        var samples = [Float](repeating: 0.5, count: 200)
        samples += [Float](repeating: 0, count: 137)
        samples += [Float](repeating: 0.5, count: 200)
        let report = Self.measure(samples)
        #expect(report.runs == 1)
        #expect(report.totalMilliseconds == 137)
        #expect(report.longestMilliseconds == 137)
        #expect(report.spanMilliseconds == 537)
    }

    @Test("many small gaps are counted and summed — the starvation shape")
    func manySmallGaps() {
        var samples: [Float] = []
        for _ in 0..<5 {
            samples += [Float](repeating: 0.5, count: 100)
            samples += [Float](repeating: 0, count: 40)
        }
        samples += [Float](repeating: 0.5, count: 100)
        let report = Self.measure(samples)
        #expect(report.runs == 5)
        #expect(report.totalMilliseconds == 200)
        #expect(report.longestMilliseconds == 40)
        #expect(report.millisecondsPerSecond == 200 / 0.8)   // span 800 ms
    }

    /// A run shorter than the minimum is a buffer boundary, not a gap an
    /// ear hears. The boundary is asserted on both sides.
    @Test("runs below the minimum are not gaps")
    func belowMinimumIgnored() {
        var samples = [Float](repeating: 0.5, count: 100)
        samples += [Float](repeating: 0, count: 19)
        samples += [Float](repeating: 0.5, count: 100)
        #expect(Self.measure(samples).runs == 0)

        var longer = [Float](repeating: 0.5, count: 100)
        longer += [Float](repeating: 0, count: 20)
        longer += [Float](repeating: 0.5, count: 100)
        #expect(Self.measure(longer).runs == 1)
    }

    /// QUIET IS NOT SILENT — the fault that killed the first metric. A
    /// very soft passage is speech, and no threshold here can call it a
    /// dropout.
    @Test("quiet speech is speech, not a dropout")
    func quietIsNotSilent() {
        var samples = [Float](repeating: 0.5, count: 100)
        samples += [Float](repeating: 0.000_001, count: 200)   // very soft
        samples += [Float](repeating: 0.5, count: 100)
        let report = Self.measure(samples)
        #expect(report.runs == 0, "an amplitude floor would have called this 200 ms of silence")
    }

    @Test("all-silent audio reports nothing rather than dividing by zero")
    func allSilent() {
        let report = Self.measure([Float](repeating: 0, count: 1000))
        #expect(report.runs == 0)
        #expect(report.spanMilliseconds == 0)
        #expect(report.millisecondsPerSecond == 0)
    }
}

/// The review's finding 15: a zero minimum counted one "run" per non-zero
/// sample, so the metric answered loudest when the audio was perfect.
extension DigitalSilenceTests {
    @Test("a zero minimum still needs a real run, not every sample boundary")
    func zeroMinimumIsNotEverySample() {
        let clean = [Float](repeating: 0.5, count: 500)
        #expect(Self.measure(clean, minimumRun: 0).runs == 0)

        var oneGap = [Float](repeating: 0.5, count: 100)
        oneGap += [Float](repeating: 0, count: 3)
        oneGap += [Float](repeating: 0.5, count: 100)
        #expect(Self.measure(oneGap, minimumRun: 0).runs == 1,
                "a zero minimum means every real run counts, not every sample")
    }
}
