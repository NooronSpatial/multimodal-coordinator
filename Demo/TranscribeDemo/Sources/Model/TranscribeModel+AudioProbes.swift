import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the audio instruments: gate calibration (AC-97),
// the echo probe (AC-96) and the shield matrix (AC-119).
extension TranscribeModel {
    /// MEASURES THE GATE INSTEAD OF GUESSING IT (AC-97).
    ///
    /// A whole field session went into two failures that feel identical
    /// — a gate above the voice (nothing ever opens) and a gate below
    /// the room (nothing ever ends) — and both were fixed by moving one
    /// slider to a value nobody could know without measuring. Worse, the
    /// right value CHANGED with the mouth: the same phone and the same
    /// voice measured a floor of 0.022–0.040 in one configuration and
    /// 0.002 in another, because the gain control settles elsewhere when
    /// the audio graph changes shape.
    ///
    /// So it is measured, here, on this device, in the configuration it
    /// is actually in. Three seconds of silence, four of speech, and the
    /// arithmetic lives in `GateCalibration` where it can be tested
    /// without a microphone.
    func calibrateGate() async {
        guard isListening, !isCalibrating else {
            calibrationStatus = "Tap Listen first."
            return
        }
        isCalibrating = true
        defer { isCalibrating = false }

        func loudest(over samples: Int) async -> Float {
            var peak: Float = 0
            for _ in 0..<samples {
                try? await Task.sleep(for: .milliseconds(100))
                peak = max(peak, microphone?.inputLevel ?? 0)
            }
            return peak
        }

        calibrationStatus = "Stay quiet…"
        let quiet = await loudest(over: 30)          // 3 s of room
        calibrationStatus = "Now speak normally…"
        let speech = await loudest(over: 40)         // 4 s of voice

        switch GateCalibration.suggestedGate(quiet: quiet, speech: speech) {
        case .gate(let suggested):
            vadThreshold = suggested                  // persists, and restarts
            calibrationStatus = String(
                format: "gate %.3f — room %.3f, voice %.3f", suggested, quiet, speech)
        case .tooClose(let quiet, let speech):
            // NOT papered over with an invented number. A gate placed
            // between two levels that are not apart is a coin toss
            // wearing three decimal places.
            calibrationStatus = String(
                format: "room %.3f and voice %.3f are too close — "
                      + "speak louder, or find a quieter place", quiet, speech)
        }
    }

    // MARK: - the echo probe (AC-96) — the phone's own numbers

    /// THE INSTRUMENT the first field run lacked.
    ///
    /// The pump publishes only sound the VAD already ACCEPTED, so "no
    /// utterances" is ambiguous — cancelled echo and a deaf microphone
    /// look identical from its output. The Mac learned this during the
    /// D-038 spike and answered it with a probe that reads the ring
    /// directly; this is that probe, in a phone's shape, and it needs no
    /// speech model at all — so it runs even where an engine will not.
    ///
    /// What it does: start capture, measure the quiet room, then SPEAK
    /// while measuring again. The difference between those two numbers,
    /// against the gate, is the whole echo question.
    func runEchoProbe() async {
        // SYMMETRIC with the shield probe (the 4d mutual-exclusion lesson,
        // third instrument): both act on the process-wide session, so
        // neither may run under the other. The 4g review flagged the
        // missing half; confirmed by reading — the shield checked the
        // echo's latch, the echo never checked the shield's.
        guard !isListening, probeStatus == nil, shieldStatus == nil else { return }
        probeStatus = "measuring the quiet room…"
        probeSilence = nil
        probeWhileSpeaking = nil

        let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 16)
        let microphone = MicrophoneSource(
            voiceProcessing: true,
            session: PhoneSession(talking: true, useSpeaker: useSpeaker))
        do {
            try microphone.start(into: producer)
        } catch {
            // NOT LEFT SET (4d review): probeStatus is both the label and
            // the re-entrancy latch, so parking an error string here
            // disabled the instrument for the life of the process — on
            // exactly the machines where a measurement matters most.
            probeFailure = "microphone: \(error.localizedDescription)"
            probeStatus = nil
            return
        }
        probeFailure = nil
        defer { microphone.stop() }
        // ASKED FOR is not GOT. Without this, a loud residual is
        // ambiguous: the canceller may have been refused by the platform,
        // or it may be running and simply never see the reply. Those need
        // opposite fixes, so the probe must not leave it to inference.
        probeVoiceProcessingActive = microphone.voiceProcessingActive
        probeRoute = useSpeaker ? "speaker" : "receiver"

        var scratch = [Float](repeating: 0, count: consumer.capacity)
        /// Reads whatever the microphone has delivered since the last read
        /// — the raw truth, gate or no gate. Safe because the pump is NOT
        /// running here, so the ring's sole-reader rule still holds.
        func measure(for seconds: Double) async -> (peak: Float, rms: Float) {
            var peak: Float = 0
            var sumOfSquares: Float = 0
            var total = 0
            let rounds = Int(seconds * 4)
            for _ in 0..<max(rounds, 1) {
                try? await Task.sleep(for: .milliseconds(250))
                scratch.withUnsafeMutableBufferPointer { buffer in
                    let result = consumer.read(into: buffer)
                    for frame in 0..<result.framesRead {
                        let sample = buffer[frame]
                        peak = max(peak, abs(sample))
                        sumOfSquares += sample * sample
                    }
                    total += result.framesRead
                }
            }
            return (peak, (sumOfSquares / Float(max(total, 1))).squareRoot())
        }

        probeSilence = await measure(for: 2)

        probeStatus = "speaking — stay quiet…"
        let speech = AVSpeechUtterance(string:
            "Measuring the echo. The microphone is listening to this sentence right now, "
            + "and the numbers on screen say whether the canceller removed it.")
        speech.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.speak(speech)
        probeWhileSpeaking = await measure(for: 6)
        synthesizer.stopSpeaking(at: .immediate)

        probeStatus = nil
    }

    /// THE SHIELD MATRIX v2 (4g, AC-119 — fourth iteration of the harness).
    ///
    /// v1's phone run caught the engine LYING TWICE: `start()` returned,
    /// the report said STARTED — and `running NO` at read time. With
    /// voice processing plus an output chain the engine starts and then
    /// kills itself inside the window, the 4e "engine killing its own
    /// graph" class; the tell is a mixer stuck at 44100 Hz against the
    /// session's 48000. v1 also contaminated arrangements through the
    /// shared session (two identical taps, different beeps heard), so v2
    /// cycles the session between arrangements — isolation, one variable.
    ///
    /// The new candidate encodes the known cure as a MEASUREMENT: observe
    /// the configuration change and RESTART the engine — 4e's
    /// reconfiguration watch counts these but never restarts. Witnesses
    /// per arrangement: session rate, engine alive at 0.5 s AND at the
    /// end, configuration changes counted, restarts attempted, frames,
    /// peak, mixer rate.
    func runShieldProbe() async {
        guard !isListening, probeStatus == nil, shieldStatus == nil else { return }
        shieldReport = []
        shieldReport.append(
            "route: \(useSpeaker ? "speaker" : "receiver") · matrix v2 · "
                + "beeps: LOW=plain MID=restart HIGH=order-swap")

        let arrangements: [Arrangement] = [
            .init(name: "1 shipping", vpInput: true, outputChain: false,
                  chainBeforeVP: false, restartOnChange: false, toneHz: 0),
            .init(name: "2 vp+chain plain (LOW)", vpInput: true, outputChain: true,
                  chainBeforeVP: false, restartOnChange: false, toneHz: 440),
            .init(name: "3 vp+chain RESTART (MID)", vpInput: true, outputChain: true,
                  chainBeforeVP: false, restartOnChange: true, toneHz: 660),
            .init(name: "4 chain-then-vp (HIGH)", vpInput: true, outputChain: true,
                  chainBeforeVP: true, restartOnChange: false, toneHz: 880)
        ]

        for arrangement in arrangements {
            shieldStatus = "arrangement \(arrangement.name)…"
            // ISOLATION: each arrangement gets a fresh session activation,
            // so one arrangement's route renegotiation cannot poison the
            // next — v1's two identical taps heard different beeps.
            let session = PhoneSession(talking: true, useSpeaker: useSpeaker)
            do { try session.activate() } catch {
                shieldReport.append("\(arrangement.name): session REFUSED — \(error.localizedDescription)")
                continue
            }
            shieldReport.append(await Self.probeArrangement(arrangement))
            session.deactivate()
            try? await Task.sleep(for: .milliseconds(300))
        }
        shieldStatus = nil
    }

    /// One arrangement of the graph, as the matrix varies it: which nodes
    /// exist, in which order they are made, whether a configuration change
    /// restarts the engine, and the tone that names it by ear.
    private struct Arrangement {
        let name: String
        let vpInput: Bool
        let outputChain: Bool
        let chainBeforeVP: Bool
        let restartOnChange: Bool
        let toneHz: Float
    }

    /// Restarts a self-stopping engine from the configuration-change
    /// notification. `@unchecked Sendable` demo-tier box: the engine is
    /// touched only from the notification queue and the probe's own
    /// teardown, which orders after removal of the observer.
    private final class EngineRestarter: @unchecked Sendable {
        let engine: AVAudioEngine
        let counts = Mutex<(changes: Int, restarts: Int)>((0, 0))
        init(_ engine: AVAudioEngine) { self.engine = engine }
        func noteChangeAndMaybeRestart(_ restart: Bool) {
            counts.withLock { $0.changes += 1 }
            guard restart, !engine.isRunning else { return }
            if (try? engine.start()) != nil {
                counts.withLock { $0.restarts += 1 }
            }
        }
    }

    private nonisolated static func probeArrangement(_ arrangement: Arrangement) async -> String {
        let name = arrangement.name
        let engine = AVAudioEngine()
        do {
            try wire(engine, as: arrangement)
        } catch {
            return "\(name): vp REFUSED — \(error.localizedDescription)"
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return "\(name): input format INVALID (\(Int(format.sampleRate)) Hz)"
        }
        let meter = Mutex<(frames: Int, peak: Float)>((0, 0))
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][frame])) }
            meter.withLock {
                $0.frames += Int(buffer.frameLength)
                $0.peak = max($0.peak, peak)
            }
        }

        let restarter = EngineRestarter(engine)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine,
            queue: nil
        ) { _ in
            restarter.noteChangeAndMaybeRestart(arrangement.restartOnChange)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            return "\(name): start REFUSED — \(error.localizedDescription)"
        }

        let player = arrangement.outputChain
            ? scheduleTone(arrangement.toneHz, on: engine) : nil
        let line = await watch(engine, meter: meter,
                               restarter: restarter, as: arrangement)

        retire(player, from: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return line
    }

    /// The two orders the matrix compares — the output chain made before
    /// voice processing, or after it.
    private nonisolated static func wire(_ engine: AVAudioEngine,
                                         as arrangement: Arrangement) throws {
        if arrangement.chainBeforeVP {
            if arrangement.outputChain { _ = engine.mainMixerNode }
            if arrangement.vpInput { try engine.inputNode.setVoiceProcessingEnabled(true) }
        } else {
            if arrangement.vpInput { try engine.inputNode.setVoiceProcessingEnabled(true) }
            if arrangement.outputChain { _ = engine.mainMixerNode }
        }
    }

    /// The beep that names an arrangement by ear, attached to the mixer and
    /// started with the engine. Nil when the mixer has no usable rate —
    /// there is then nothing to play it through.
    private nonisolated static func scheduleTone(
        _ toneHz: Float, on engine: AVAudioEngine
    ) -> AVAudioPlayerNode? {
        let mixerRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard mixerRate > 0,
              let toneFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: mixerRate, channels: 1,
                                             interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat,
                                            frameCapacity: AVAudioFrameCount(mixerRate * 2))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(mixerRate * 2)
        if let channel = buffer.floatChannelData {
            for frame in 0..<Int(buffer.frameLength) {
                channel[0][frame] = 0.4 * sinf(2 * .pi * toneHz * Float(frame) / Float(mixerRate))
            }
        }
        let tonePlayer = AVAudioPlayerNode()
        engine.attach(tonePlayer)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: toneFormat)
        tonePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if engine.isRunning { tonePlayer.play() }
        return tonePlayer
    }

    /// The watching itself, and the row it produces: what the tap heard,
    /// whether the engine was alive at 0.5 s and at the end, how many
    /// configuration changes and restarts happened, and the two rates.
    private nonisolated static func watch(
        _ engine: AVAudioEngine,
        meter: borrowing Mutex<(frames: Int, peak: Float)>,
        restarter: EngineRestarter,
        as arrangement: Arrangement
    ) async -> String {
        try? await Task.sleep(for: .milliseconds(500))
        let aliveEarly = engine.isRunning
        try? await Task.sleep(for: .milliseconds(2000))
        let (frames, peak) = meter.withLock { $0 }
        let aliveEnd = engine.isRunning
        let (changes, restarts) = restarter.counts.withLock { $0 }
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        let mixerRate = arrangement.outputChain
            ? engine.mainMixerNode.outputFormat(forBus: 0).sampleRate : 0

        var line = String(format: "%@: frames %d · peak %.4f · alive %@/%@ · cfg %d · restarts %d · session %.0f",
                          arrangement.name, frames, peak,
                          aliveEarly ? "y" : "N", aliveEnd ? "y" : "N",
                          changes, restarts, sessionRate)
        if arrangement.outputChain { line += String(format: " · mixer %.0f", mixerRate) }
        return line
    }

    /// Gives the tone player back: stopped, then detached only while it is
    /// still attached AND still connected.
    private nonisolated static func retire(_ player: AVAudioPlayerNode?,
                                           from engine: AVAudioEngine) {
        guard let player else { return }
        player.stop()
        if engine.attachedNodes.contains(player),
           !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty {
            engine.detach(player)
        }
    }
}
