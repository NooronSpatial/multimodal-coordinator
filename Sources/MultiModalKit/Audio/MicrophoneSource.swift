import AVFoundation
import Synchronization

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

    /// HOW MANY TIMES THE ENGINE RECONFIGURED ITSELF, and whether it is
    /// still running.
    ///
    /// `AVAudioEngine` STOPS ITS OWN GRAPH when the audio route or the
    /// hardware format changes, and it posts a notification rather than
    /// asking. Nothing in this project ever observed it. The result on a
    /// phone is the worst kind of failure: the microphone indicator
    /// appears for an instant and vanishes, no error is thrown, no row
    /// appears, and a person reports "the mic is not working at all"
    /// with nothing to look at. Ryad reported exactly that.
    ///
    /// Counting it does not fix it. It makes it VISIBLE, which is the
    /// difference between a bug and a mystery.
    public var configurationChanges: Int { reconfigurations.count }
    /// How many times a hosting engine was restarted after stopping
    /// itself on a configuration change (4g, INSTRUMENTS §23). Zero on
    /// every non-hosting engine, by construction — the cure exists only
    /// where the measurement said it works.
    public var engineRestarts: Int { restarts.count }
    /// Whether the reconfiguration watch is actually installed. Public
    /// because the counter above was silently orphaned once: a reader
    /// who can see `0` but cannot see whether anyone is counting has no
    /// way to tell "nothing happened" from "nobody is watching".
    public var isWatchingConfiguration: Bool { configurationObserver != nil }
    /// Boxed for the same reason the level is: a notification closure is
    /// `@Sendable`, and this class is not — so what crosses into it is a
    /// tiny object holding one atomic, never `self`.
    private let reconfigurations = ReconfigurationCount()
    private let restarts = ReconfigurationCount()
    /// True while the engine's graph is actually running. `isRunning`
    /// above is OUR intent; this is the engine's own answer, and they
    /// disagree exactly when something has gone wrong behind our back.
    public var engineIsRunning: Bool { engine.isRunning }
    private var configurationObserver: (any NSObjectProtocol)?

    /// THE RAW INPUT LEVEL, ungated (AC-97).
    ///
    /// Everything else this pipeline shows a person is downstream of the
    /// VAD gate, which means that when the gate is set wrong there is
    /// nothing to look at — and a gate can be wrong in two opposite
    /// ways that feel identical from outside. Too HIGH and no utterance
    /// ever opens; too LOW and one opens, never ends, and no reply is
    /// ever produced. Both look like "I speak and nothing happens".
    /// This number tells them apart, and it tells a person where to put
    /// the gate instead of making them guess.
    ///
    /// Lock-free on purpose. It is written from the tap — the audio
    /// thread, where the iron laws forbid locks and allocation — so it
    /// is one relaxed atomic store of a float's bit pattern. No lock, no
    /// allocation, no ordering guarantee needed: a level meter that
    /// reads a value one buffer stale is still a correct level meter.
    private let latestLevel = InputLevelBox()

    /// The most recent 20 ms RMS the microphone delivered, gate or no
    /// gate. Read it as often as a screen refreshes.
    public var inputLevel: Float { latestLevel.level }

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
        // THE ORDER, FOURTH ATTEMPT — and this one was measured on the
        // PHONE, by the 4g shield matrix, not inferred from a Mac. The
        // history, kept because each line cost a field trip:
        //
        //   format → tap → mixer   the phone went DEAF: creating the
        //                          mixer renegotiates the unit, and the
        //                          tap was already holding a dead format
        //   mixer → format → tap   (Mac) inputFormat returned 0 Hz and
        //                          capture could not start at all
        //   vp → mixer → …         (the third attempt) STARTS — and on
        //                          the phone the mixer binds at 44100 Hz
        //                          against a 48000 Hz session, a
        //                          configuration change fires, and in
        //                          one measured shape the engine stopped
        //                          itself dead (INSTRUMENTS §23)
        //   MIXER → VP → …         zero configuration changes, mixer at
        //                          the session's own rate, tone audible
        //                          AND cancelled to peak 0.03–0.08
        //                          against the disease's 1.0 — the
        //                          calmest graph the matrix found
        //
        // So when this engine hosts playback, the output half is built
        // FIRST and the voice-processing unit second — it then
        // negotiates against a graph whose output side already exists.
        if hostsPlayback {
            _ = engine.mainMixerNode
        }
        if voiceProcessing {
            // BEFORE the format read: the unit re-negotiates the input format
            // (this Mac: 48 kHz stays, but that is a measurement, not a law).
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingActive = input.isVoiceProcessingEnabled
        }
        engine.prepare()

        // `inputFormat`, AND A CORRECTION OF MY OWN CORRECTION.
        //
        // This was briefly changed to `outputFormat`, on the reasoning
        // that a tap observes what a node PRODUCES — which sounds right
        // and is wrong. `installTap` asserts on the INPUT HARDWARE
        // format, in those words:
        //
        //   required condition is false:
        //   format.sampleRate == inputHWFormat.sampleRate
        //
        // and an ObjC assertion aborts the process. It only fires when
        // the two formats disagree, which is why it passed every local
        // run and then killed 39 of 40 rounds the moment something else
        // on the machine changed the audio configuration.
        //
        // The observation that motivated the change was real —
        // `inputFormat` collapses to 0 Hz once `mainMixerNode` is
        // touched — but that only happened in the `hostsPlayback`
        // arrangement, which D-049 removed. A fix aimed at a
        // configuration that no longer exists, breaking the one that
        // does.
        let format = input.inputFormat(forBus: 0)
        // VALIDATED, because the alternative is not an error — it is an
        // ABORT. `installTap` asserts on a format with no rate or no
        // channels and takes the process with it, which is how a
        // microphone that is merely unavailable becomes a crash report.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceFailure.inputUnavailable(
                sampleRate: format.sampleRate, channels: format.channelCount)
        }
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [latestLevel] buffer, _ in
            // Iron laws territory. View → copy → return. Nothing else.
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            producer.write(UnsafeBufferPointer(start: channels[0], count: frames))

            // The level, computed here because here is the only place
            // the RAW signal exists — everywhere downstream is gated.
            // A loop and one relaxed atomic store: no lock, no
            // allocation, nothing that can block a render callback.
            var sumOfSquares: Float = 0
            for index in 0..<frames {
                let sample = channels[0][index]
                sumOfSquares += sample * sample
            }
            let rms = (sumOfSquares / Float(max(frames, 1))).squareRoot()
            latestLevel.store(rms)
        }

        // WATCH FOR THE ENGINE KILLING ITS OWN GRAPH. Installed before
        // `start`, because a reconfiguration provoked BY starting is
        // exactly the one that was invisible.
        //
        // This registration was deleted once, silently, when `start` was
        // rewritten — leaving `removeObserver` in `stop`, a counter with
        // no writer, and a screen showing "reconfig 0" as if it were
        // evidence. A doc-versus-code audit found it, no test could
        // have, and it is the same dead-instrument fault this milestone
        // has now committed three times. Hence the property below: an
        // instrument that cannot be asked whether it is switched on is
        // an instrument that will be switched off again.
        let restartBox: EngineRestartBox? = hostsPlayback
            ? EngineRestartBox(engine: engine, restarts: restarts) : nil
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [reconfigurations] _ in
            reconfigurations.increment()
            // THE CURE, measured before it was written (D-054's order):
            // the 4g matrix ran an arrangement whose only difference was
            // restart-on-change, and it fired once and HELD — capture
            // alive, tone audible, canceller working (INSTRUMENTS §23).
            // Hosting engines only: the shipping arrangement keeps the
            // watch-and-count behavior it has had since 4e, byte for
            // byte. The old warning stands for the rest: restarting a
            // graph from inside its own notification is how a loop gets
            // built, so the box refuses when the engine already runs.
            restartBox?.restartIfStopped()
        }

        // Already prepared above, before the format was read.
        //
        // AND THE THROW PATH CLEANS UP ITS OWN ARMS — the 4g review's one
        // confirmed finding, reproduced in a harness before it was fixed:
        // if start() threw here, the tap and the configuration observer
        // survived, `isRunning` never became true, so `stop()`'s guard
        // meant nothing could EVER remove them. Pre-4g that leak merely
        // miscounted reconfigurations; with a hosting engine the leaked
        // observer holds an ARMED restart box — a later route change
        // could start capture with a stale tap into the old ring, no
        // session of ours active, while this type reports stopped. A
        // microphone that records while the app says it does not is the
        // one bug this project must never ship. (The second half of the
        // reproduction: a retry would not have rescued it — the leaked
        // tap makes the next installTap abort the process.)
        do {
            try engine.start()
        } catch {
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
            }
            configurationObserver = nil
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        // The host may take replies only now: it refuses to attach to an
        // engine that is not pulling, and until this line it was not.
        playbackHost.captureStarted()
        captureBegan = true          // the session is now in use; keep it
    }

    public func stop() {
        guard isRunning else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
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


/// One atomic float, in a box that a closure can capture.
///
/// `Atomic` is non-copyable, so a capture list cannot take it out of the
/// object that owns it — the same wall `Mutex` puts up, and the same
/// answer: a small class whose only job is to be referenceable. It has
/// no other members on purpose.
///
/// `@unchecked Sendable` with a one-line proof: the only state is an
/// atomic, and every access is a relaxed load or store. There is nothing
/// to tear and nothing to order — a level meter reading one buffer stale
/// is still a correct level meter.
/// One atomic counter, boxed so a `@Sendable` notification closure can
/// hold it without holding the capture object.
final class ReconfigurationCount: @unchecked Sendable {
    private let value = Atomic<Int>(0)
    func increment() { value.wrappingAdd(1, ordering: .relaxed) }
    var count: Int { value.load(ordering: .relaxed) }
}

/// The engine and the restart counter, boxed for the notification
/// closure (4g). `@unchecked Sendable` with the proof written out: the
/// engine is touched from exactly one place here — the configuration-
/// change notification, which AVFoundation serializes per engine — and
/// only when it is NOT running, so the box never races the render thread
/// of a live graph. `isRunning`/`start` are the same calls the probe's
/// arrangement made, measured working (INSTRUMENTS §23).
final class EngineRestartBox: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let restarts: ReconfigurationCount
    init(engine: AVAudioEngine, restarts: ReconfigurationCount) {
        self.engine = engine
        self.restarts = restarts
    }
    func restartIfStopped() {
        guard !engine.isRunning else { return }
        if (try? engine.start()) != nil { restarts.increment() }
    }
}

final class InputLevelBox: @unchecked Sendable {
    private let value = Atomic<UInt32>(0)
    /// Called from the audio thread. No lock, no allocation.
    func store(_ level: Float) {
        value.store(level.bitPattern, ordering: .relaxed)
    }
    var level: Float { Float(bitPattern: value.load(ordering: .relaxed)) }
}
