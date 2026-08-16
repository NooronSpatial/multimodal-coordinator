import AVFoundation

/// Real microphone capture via `AVAudioEngine.installTap` (D-001, option A).
///
/// The tap callback runs on an audio delivery thread and obeys the iron laws:
/// it VIEWS the incoming buffer, COPIES channel 0 into the ring, and RETURNS.
/// No locks, no allocation, no printing, no I/O — the ring's producer handle
/// is the only thing it touches, and that handle never waits.
///
/// The planned upgrade to `AVAudioSinkNode` (closer to the true real-time
/// callback) is documented in D-001 and deliberately NOT built yet (AC-8).
public final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    /// Whether capture is live. Public because an app showing a
    /// microphone indicator wants it — and because the session seam's
    /// second promise ("released only AFTER the engine stops") cannot be
    /// PINNED by a test without something to observe. The 4d review found
    /// that promise asserted in a message and verified by nothing.
    public private(set) var isRunning = false
    /// SPIKE-LEVEL (4b fork F-2 = A, spike-gated): ask the platform for its
    /// voice-processing input unit — echo cancellation, noise suppression and
    /// AGC in one switch. Default false = byte-for-byte the pre-4b tap.
    ///
    /// Honest scope, MEASURED on this Mac (the numbers live in INSTRUMENTS.md
    /// §"the echo loop"). This comment first claimed the opposite — that the
    /// canceller would only subtract what this engine itself renders, leaving
    /// another path's audio (AVSpeechSynthesizer, `say`) untouched — and that
    /// the AGC would lift room noise toward the gate. The spike refuted both:
    /// speaker audio from a SEPARATE process vanished from the tap (peak
    /// 0.136 → 0.008) and the noise floor FELL (0.0045 → 0.0016 rms). The
    /// wrong prediction stays on the record; the measurement rules.
    ///
    /// What is still not proven here: that the reply stays comfortably
    /// audible to a human while this is on, and that a human voice still
    /// opens an utterance. Both need ears and a voice in the room.
    private let voiceProcessing: Bool

    /// The hardware's sample rate, known after `start`. (48,000 on most Macs.)
    public private(set) var sampleRate: Double = 0

    /// True when the platform actually granted voice processing — asked for
    /// is not the same as got, and the caller deserves the difference.
    public private(set) var voiceProcessingActive = false

    /// The platform session this capture rides on (AC-93, D-042 F-1 = B).
    /// The library calls its steps in order; the app supplies their
    /// contents. `nil` on macOS, which has no session to manage.
    ///
    /// RED skeleton: stored, not yet obeyed.
    private let session: (any AudioSessionConfiguring)?

    /// WHERE A REPLY CAN SPEAK FROM (AC-108, D-048).
    ///
    /// D-043 measured that iOS voice processing subtracts only what its
    /// own audio unit renders, and that unit is the one behind this
    /// engine. So a reply rendered through this host is the FIRST reply
    /// the canceller can possibly remove from what the microphone hears
    /// — which is the hypothesis AC-104 goes to the phone to test.
    ///
    /// A separate object rather than a conformance on this class, and
    /// that is the compiler's doing: a host is touched by whoever owns
    /// capture AND by the mouth's own queue, so it must be `Sendable`,
    /// and an audio-capture class full of engine state is not. The
    /// handle holds a lock and an engine reference and nothing else.
    public let playbackHost: MicrophonePlaybackHost

    /// Whether replies will be rendered on this engine (AC-108).
    ///
    /// It has to be known BEFORE capture starts, which is why it is an
    /// init parameter and not a fact discovered when the first reply
    /// arrives. See `start` for what it does and why the field forced it.
    private let hostsPlayback: Bool

    public init(voiceProcessing: Bool = false,
                session: (any AudioSessionConfiguring)? = nil,
                hostsPlayback: Bool = false) {
        self.voiceProcessing = voiceProcessing
        self.session = session
        self.hostsPlayback = hostsPlayback
        self.playbackHost = MicrophonePlaybackHost(engine: engine)
    }

    public func start(into producer: AudioRingProducer) throws {
        guard !isRunning else { return }

        // THE ORDER (D-042 F-1): the session is made ready BEFORE the
        // format is read or the tap is installed — read it from a session
        // that was never activated and the format can shift underneath
        // the tap later. If the app refuses, capture is not attempted at
        // all: the error leaves here, and nothing was opened to release.
        try session?.activate()
        var captureBegan = false
        defer {
            // Every throwing path below leaves through here. A session we
            // activated and then failed to use must not be left active —
            // on iOS that is another app's audio held hostage.
            if !captureBegan { session?.deactivate() }
        }

        let input = engine.inputNode
        if voiceProcessing {
            // BEFORE the format read: the unit re-negotiates the input format
            // (this Mac: 48 kHz stays, but that is a measurement, not a law).
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingActive = input.isVoiceProcessingEnabled
        }
        // THE OUTPUT CHAIN IS BUILT BEFORE THE FORMAT IS READ, and the
        // position of these two lines is the whole fix — twice over.
        //
        // Reading `mainMixerNode` is not a query: it CREATES the mixer
        // and wires it to the output node. Until it existed at all, the
        // first REPLY did that, building the output half of a live
        // voice-processing unit while it rendered, and the phone logged
        //     throwing -1 from AU (…): auou/vpio/appl, render err: -1
        // over and over while the app sat in "thinking".
        //
        // Then it was added — below the tap — and the phone went
        // completely DEAF. Same reason, one step later: changing the
        // graph's shape renegotiates the I/O unit, and the tap had
        // already been installed with a format the hardware no longer
        // used. Both symptoms are one rule, learned from both sides:
        //
        //     build the whole graph FIRST, read formats SECOND,
        //     install the tap THIRD, start LAST.
        //
        // Gated on `hostsPlayback` because a listen-only pipeline must
        // not grow an output chain it never uses — that would change
        // what every earlier measurement in this project was measuring.
        if hostsPlayback {
            _ = engine.mainMixerNode
        }

        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Iron laws territory. View → copy → return. Nothing else.
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            producer.write(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        // The host may take replies only now: it refuses to attach to an
        // engine that is not pulling, and until this line it was not.
        playbackHost.captureStarted()
        captureBegan = true          // the session is now in use; keep it
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        // BEFORE the engine stops, and that order is a CRASH FIX, not a
        // preference. This line used to sit after `engine.stop()`, with
        // a comment claiming that was the safe place. It is the exact
        // opposite: once the engine has stopped, a reply's player node
        // is no longer in the graph's input or output chain, and
        // `AVAudioEngine.detach` asserts on precisely that —
        //
        //   required condition is false:
        //   graphNode->IsNodeState(kAUGraphNodeState_InInputChain) ||
        //   graphNode->IsNodeState(kAUGraphNodeState_InOutputChain)
        //
        // — which is an ObjC assertion, so it aborts the process rather
        // than throwing something Swift could catch. Found on Ryad's
        // iPhone, in the field, within minutes of the seam shipping.
        playbackHost.captureStopped()
        engine.stop()
        isRunning = false
        // AFTER the engine has stopped, never before: releasing a session
        // out from under a running graph is the other half of the bug.
        session?.deactivate()
    }
}
