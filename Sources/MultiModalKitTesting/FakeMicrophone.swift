import MultiModalKit

/// A scripted stand-in for the microphone (SPEC AC-7).
///
/// Tests drive it by hand: `emit(_:)` plays the role of the hardware
/// delivering one chunk. Single-threaded by design — tests own it fully.
public final class FakeMicrophone: AudioSource {
    private var producer: AudioRingProducer?

    public init() {}

    public func start(into producer: AudioRingProducer) throws {
        self.producer = producer
    }

    public func stop() {
        producer = nil
    }

    /// Deliver one chunk, as if the hardware called back with it.
    /// Ignored when the source is not started — real hardware can't call
    /// back before it exists either.
    public func emit(_ samples: [Float]) {
        guard let producer else { return }
        samples.withUnsafeBufferPointer { producer.write($0) }
    }
}
