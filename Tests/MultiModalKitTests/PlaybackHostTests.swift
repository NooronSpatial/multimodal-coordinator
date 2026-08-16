import Testing
import AVFAudio
@testable import MultiModalKit

/// WHERE A REPLY IS RENDERED (SPEC AC-108, D-048).
///
/// D-043 measured that iOS voice processing removes only what its OWN
/// audio unit renders. That unit lives on the microphone's engine, so a
/// reply the canceller can see must be rendered THERE — and until now
/// `MicrophoneSource` kept its engine private.
///
/// The seam does not hand the engine out. It hands out two verbs, and
/// keeps the ORDER — the same division `AudioSessionConfiguring` uses:
/// the library owns the sequence, the caller owns the values.
///
/// **The rule worth testing without hardware** is the one that bites:
/// attaching to a host that is not rendering must FAIL LOUDLY. A silent
/// attach produces a node that is connected to a graph nobody is
/// pulling, so its buffers are never played — which, with
/// `.dataPlayedBack` completions, means the reply never reports finished
/// and the turn hangs. That is not a hypothetical: it hung the WER tool
/// at 0% CPU for twenty minutes today (INSTRUMENTS §14).
@Suite("Playback hosts — where a reply is allowed to render")
struct PlaybackHostTests {

    // MARK: - the microphone as a host

    @Test("attaching to a microphone that is not capturing fails loudly")
    func attachingToAStoppedMicrophoneThrows() {
        let microphone = MicrophoneSource()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 24_000, channels: 1, interleaved: false)!

        #expect(throws: PlaybackHostFailure.notRendering) {
            try microphone.playbackHost.attachForPlayback(player, format: format)
        }
        #expect(!microphone.playbackHost.isRendering)
    }

    /// A mouth tears itself down on cancel, on failure, and on finish,
    /// and those paths can overlap. Detaching something that was never
    /// attached — or detaching twice — must be a no-op, not a crash in
    /// an audio graph.
    @Test("detaching a node that was never attached is harmless")
    func detachingAStrangerIsHarmless() {
        let microphone = MicrophoneSource()
        let player = AVAudioPlayerNode()
        microphone.playbackHost.detachFromPlayback(player)
        microphone.playbackHost.detachFromPlayback(player)
        #expect(microphone.playbackHost.hostedCount == 0)
    }

    // MARK: - the plain engine host

    /// The seam's SECOND implementation, which is why this is a seam and
    /// not a method with an interface drawn around it. It exists for
    /// every machine with no capture in the picture: the bake-off tool,
    /// the Mac demo, a test.
    @Test("a plain engine host attaches, renders, and gives the node back")
    func engineHostAttachesAndDetaches() throws {
        let host = AudioEnginePlaybackHost()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 24_000, channels: 1, interleaved: false)!

        try host.attachForPlayback(player, format: format)
        // THE ORDER IS THE PRODUCT. The engine must be running only
        // AFTER a source node is attached and connected: an engine
        // started with an empty graph never pulls, so anything attached
        // afterwards renders nothing. That exact mistake produced a
        // twenty-minute hang, and this is the assertion that pins it.
        #expect(host.isRendering, "attaching must leave the host actually rendering")

        host.detachFromPlayback(player)
        host.detachFromPlayback(player)      // twice is a no-op, not a crash
    }

    @Test("a host takes several replies in turn")
    func engineHostTakesSeveralNodes() throws {
        let host = AudioEnginePlaybackHost()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 24_000, channels: 1, interleaved: false)!
        let players = (0..<3).map { _ in AVAudioPlayerNode() }
        for player in players {
            try host.attachForPlayback(player, format: format)
        }
        #expect(host.hostedCount == 3)
        for player in players {
            host.detachFromPlayback(player)
        }
        #expect(host.hostedCount == 0, "every reply gives its node back")
    }

    /// The leak this seam exists to make impossible to forget. Before
    /// AC-108 the mouth attached a player per reply and detached none,
    /// so a long conversation grew its audio graph without bound
    /// (INSTRUMENTS §14). The host counts, so the count can be asserted.
    @Test("a host that is torn down keeps no nodes")
    func teardownReleasesEverything() throws {
        let host = AudioEnginePlaybackHost()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 24_000, channels: 1, interleaved: false)!
        for _ in 0..<5 {
            try host.attachForPlayback(AVAudioPlayerNode(), format: format)
        }
        #expect(host.hostedCount == 5)
        host.stopRendering()
        #expect(host.hostedCount == 0)
        #expect(!host.isRendering)
    }
}
