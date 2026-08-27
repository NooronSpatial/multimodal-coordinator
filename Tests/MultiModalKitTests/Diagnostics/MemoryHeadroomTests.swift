import Testing
@testable import MultiModalKit

/// AC-132: the instrument must be able to say whether it is switched on.
@Suite("AC-132 · the headroom instrument never reports an ambiguous zero")
struct MemoryHeadroomTests {

    /// THE POINT OF THE WHOLE TYPE. `exhausted` and `unavailable` are the
    /// two facts Apple's APIs collapse into the same 0, and confusing
    /// them means either a Mac that thinks it is dying or a phone that
    /// thinks it is safe.
    @Test("exhausted and unavailable are never the same answer")
    func zeroIsNotOneThing() {
        let exhausted = MemoryHeadroom.exhausted
        let absent = MemoryHeadroom.unavailable(.noMemoryLimitOnThisPlatform)
        #expect(exhausted != absent)
        #expect(exhausted.megabytes == 0)      // a number: none left
        #expect(absent.megabytes == nil)       // no number at all
        #expect(exhausted.isMeasuring)         // the instrument IS on
        #expect(absent.isMeasuring == false)   // the instrument is OFF
    }

    @Test("a real reading reports both a number and that it is measuring")
    func aRealReadingIsMeasuring() {
        let headroom = MemoryHeadroom.bytes(512 * 1_048_576)
        #expect(headroom.megabytes == 512)
        #expect(headroom.isMeasuring)
    }

    @Test("every unavailable reason is distinct — a caller can tell them apart")
    func reasonsAreDistinguishable() {
        let reasons: [MemoryHeadroom.Reason] = [
            .noMemoryLimitOnThisPlatform,
            .taskInfoFailed(5),
            .fieldNotReported
        ]
        for (index, reason) in reasons.enumerated() {
            for (otherIndex, otherReason) in reasons.enumerated() where index != otherIndex {
                #expect(MemoryHeadroom.unavailable(reason) != MemoryHeadroom.unavailable(otherReason))
            }
        }
    }

    /// THE PLATFORM CONTROL, and it is the reason this file is not just
    /// arithmetic. On a Mac the reader MUST answer `unavailable`, because
    /// `limit_bytes_remaining` was MEASURED returning 0 here with the
    /// full field count — populated, and genuinely zero, because a Mac
    /// has no dirty memory limit. Reporting that as `exhausted` would
    /// tell this machine it is about to be killed.
    @Test("on this Mac the reader refuses to invent a number")
    func macReportsUnavailableRatherThanZero() {
        let reading = MemoryHeadroomReader.read()
        #if os(macOS)
        #expect(reading == .unavailable(.noMemoryLimitOnThisPlatform))
        #expect(reading.isMeasuring == false)
        #expect(reading.megabytes == nil)
        #else
        #expect(reading.isMeasuring, "on a device the instrument must be ON")
        #endif
    }
}
