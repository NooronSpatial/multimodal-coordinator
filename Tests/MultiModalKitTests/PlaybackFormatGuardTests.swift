import AVFAudio
import Testing
@testable import MultiModalKit

/// THE 0 Hz GUARD — from a crash on Ryad's phone (INSTRUMENTS §26).
///
/// `-[AVAudioEngine connect:to:format:]` does not fail on an invalid
/// format, it raises an ObjC exception, and Swift cannot catch that: the
/// app is terminated. So the format must be checked BEFORE the call, and
/// these tests exist to keep that check alive.
///
/// A warning for whoever deletes the guard: this suite will not go red,
/// it will ABORT the whole test process — the same way the app did. That
/// is not a flaw in the test, it is the fault being faithfully
/// reproduced, and it was measured in a standalone harness before the
/// guard was written.
@Suite("the 0 Hz guard — an invalid format must throw, never abort")
struct PlaybackFormatGuardTests {

    /// The exact shape the phone reported: `outf< 1 ch, 0 Hz, Float32>`.
    private static var zeroHz: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)!
    }

    @Test("a 0 Hz format is refused by name, not by crashing")
    func zeroHzIsRefused() throws {
        let host = AudioEnginePlaybackHost()
        #expect(throws: PlaybackHostFailure.unusableFormat(rate: 0, channels: 1)) {
            try host.attachForPlayback(AVAudioPlayerNode(), format: Self.zeroHz)
        }
    }

    @Test("the refusal carries the numbers, so a report says what was wrong")
    func theRefusalIsSpecific() {
        do {
            try PlaybackHostFailure.requireUsable(Self.zeroHz)
            Issue.record("a 0 Hz format must not be accepted")
        } catch let failure as PlaybackHostFailure {
            #expect(failure == .unusableFormat(rate: 0, channels: 1))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("a sane format passes the check — the guard is not simply always-no")
    func aSaneFormatPasses() throws {
        let good = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try PlaybackHostFailure.requireUsable(good)   // must not throw
        #expect(good.sampleRate == 48_000)
    }

    /// The microphone host refuses first for a DIFFERENT reason, and that
    /// ordering matters: rendering into a stopped capture engine buys
    /// nothing even when the format is perfect.
    @Test("the microphone host still refuses when it is not capturing")
    func microphoneHostRefusesWhenNotCapturing() {
        let host = MicrophonePlaybackHost(engine: AVAudioEngine())
        let good = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        #expect(throws: PlaybackHostFailure.notRendering) {
            try host.attachForPlayback(AVAudioPlayerNode(), format: good)
        }
    }
}
