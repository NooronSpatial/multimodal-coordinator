import MultiModalKit
import Testing

/// SPEC AC-7 — the capture seam, exercised with the scripted fake.
/// (The real microphone is deliberately untestable here: hardware. Its
/// correctness argument is the iron-laws code shape, reviewed by eye,
/// and the live demo.)
@Suite(.timeLimit(.minutes(1))) struct AudioSourceTests {

    private func read(_ consumer: AudioRingConsumer, max: Int) -> [Float] {
        var buffer = [Float](repeating: .nan, count: max)
        let result = buffer.withUnsafeMutableBufferPointer { consumer.read(into: $0) }
        return Array(buffer.prefix(result.framesRead))
    }

    @Test func emittedChunksFlowThroughTheRingInOrder() throws {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 64)
        let microphone = FakeMicrophone()
        try microphone.start(into: producer)
        microphone.emit([1, 2, 3])
        microphone.emit([4, 5])
        #expect(read(consumer, max: 16) == [1, 2, 3, 4, 5])
    }

    @Test func emitBeforeStartDeliversNothing() throws {
        let (_, consumer) = AudioRing.create(minimumCapacity: 64)
        let microphone = FakeMicrophone()
        microphone.emit([1, 2, 3])                       // no start — into the void
        #expect(read(consumer, max: 16).isEmpty)
    }

    @Test func stopDisconnectsTheSource() throws {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 64)
        let microphone = FakeMicrophone()
        try microphone.start(into: producer)
        microphone.emit([1, 2])
        microphone.stop()
        microphone.emit([3, 4])                          // after stop — ignored
        #expect(read(consumer, max: 16) == [1, 2])
    }
}
