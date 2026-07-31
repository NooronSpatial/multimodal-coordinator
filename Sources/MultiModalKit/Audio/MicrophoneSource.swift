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
    private var running = false

    /// The hardware's sample rate, known after `start`. (48,000 on most Macs.)
    public private(set) var sampleRate: Double = 0

    public init() {}

    public func start(into producer: AudioRingProducer) throws {
        guard !running else { return }
        let input = engine.inputNode
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
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
