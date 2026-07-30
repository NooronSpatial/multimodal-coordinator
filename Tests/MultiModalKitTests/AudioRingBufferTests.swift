import MultiModalKit
import Testing

/// SPEC AC-1…AC-5 — the ring buffer, tested alone (it has no clocks, no
/// audio, no concurrency inside — a pure component).
/// Time limit = hang safety net only; no test here depends on real time.
@Suite(.timeLimit(.minutes(1))) struct AudioRingBufferTests {

    /// Helper: write an array of Floats through the hot-path API.
    private func write(_ producer: AudioRingProducer, _ values: [Float]) {
        values.withUnsafeBufferPointer { producer.write($0) }
    }

    /// Helper: read up to `max` frames into a fresh array.
    private func read(_ consumer: AudioRingConsumer, max: Int) -> (values: [Float], result: AudioRingConsumer.ReadResult) {
        var buffer = [Float](repeating: .nan, count: max)
        let result = buffer.withUnsafeMutableBufferPointer { consumer.read(into: $0) }
        return (Array(buffer.prefix(result.framesRead)), result)
    }

    @Test func capacityRoundsUpToPowerOfTwo() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 100)
        #expect(producer.capacity == 128)
        #expect(consumer.capacity == 128)
    }

    @Test func roundtripPreservesOrderAndValues() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 128)
        write(producer, [1, 2, 3, 4, 5])
        let (values, result) = read(consumer, max: 16)
        #expect(values == [1, 2, 3, 4, 5])
        #expect(result == .init(framesRead: 5, framesDropped: 0))
    }

    @Test func emptyReadReturnsNothing() {
        let (_, consumer) = AudioRing.create(minimumCapacity: 8)
        let (values, result) = read(consumer, max: 8)
        #expect(values.isEmpty)
        #expect(result == .init(framesRead: 0, framesDropped: 0))
    }

    @Test func wraparoundKeepsOrderAcrossTheSeam() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 8)
        write(producer, [1, 2, 3, 4, 5, 6])
        _ = read(consumer, max: 6)
        write(producer, [7, 8, 9, 10, 11, 12])          // wraps around the end
        let (values, result) = read(consumer, max: 8)
        #expect(values == [7, 8, 9, 10, 11, 12])
        #expect(result.framesDropped == 0)
    }

    @Test func partialReadsDeliverInOrder() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 16)
        write(producer, [1, 2, 3, 4, 5, 6, 7, 8])
        let first = read(consumer, max: 3)
        let second = read(consumer, max: 3)
        let third = read(consumer, max: 10)
        #expect(first.values == [1, 2, 3])
        #expect(second.values == [4, 5, 6])
        #expect(third.values == [7, 8])
    }

    @Test func overflowOverwritesOldestAndCountsExactly() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 8)
        write(producer, [1, 2, 3, 4, 5, 6, 7, 8])       // full
        write(producer, [9, 10, 11, 12])                // overwrites 1...4
        let (values, result) = read(consumer, max: 16)
        #expect(values == [5, 6, 7, 8, 9, 10, 11, 12])  // newest 8 survive
        #expect(result.framesDropped == 4)              // exactly the 4 oldest
        #expect(consumer.totalDropped == 4)
    }

    @Test func droppedFramesAccumulateAcrossOverruns() {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 4)
        write(producer, [1, 2, 3, 4, 5, 6])             // drops 2
        _ = read(consumer, max: 4)
        write(producer, [7, 8, 9, 10, 11, 12])          // drops 2 again
        _ = read(consumer, max: 4)
        #expect(consumer.totalDropped == 4)
    }

    /// Stress: a fast writer task races a slow reader task. Scheduling is not
    /// deterministic, so we assert INVARIANTS that must hold on every run:
    /// every read chunk is a contiguous ascending run, and at the end
    /// frames-read + frames-dropped == frames-written, with no value ever
    /// delivered twice or out of order.
    @Test func stressAccountingBalancesAndOrderSurvives() async {
        let (producer, consumer) = AudioRing.create(minimumCapacity: 256)
        let totalFrames = 100_000
        let chunk = 64

        let writer = Task.detached {
            var next = 0
            while next < totalFrames {
                let n = min(chunk, totalFrames - next)
                let values = (0..<n).map { Float(next + $0) }
                values.withUnsafeBufferPointer { producer.write($0) }
                next += n
            }
        }

        var delivered = 0
        var dropped = 0
        var highestSeen = -1
        var orderViolations = 0
        var buffer = [Float](repeating: .nan, count: 128)
        // Spin cap: bounded so a broken buffer FAILS the accounting asserts
        // below instead of hanging the suite forever (fail fast, never hang).
        var spins = 0
        while delivered + dropped < totalFrames && spins < 200_000 {
            spins += 1
            let result = buffer.withUnsafeMutableBufferPointer { consumer.read(into: $0) }
            if result.framesRead > 0 {
                for i in 0..<result.framesRead {
                    let value = Int(buffer[i])
                    if value <= highestSeen { orderViolations += 1 }
                    highestSeen = value
                }
                delivered += result.framesRead
            }
            dropped += result.framesDropped
            if result.framesRead == 0 && result.framesDropped == 0 {
                await Task.yield()                       // let the writer run
            }
        }
        await writer.value

        #expect(orderViolations == 0)                    // never backwards, never twice
        #expect(delivered + dropped == totalFrames)      // every frame accounted for
        #expect(consumer.totalDropped == dropped)        // the public counter agrees
        #expect(highestSeen == totalFrames - 1)          // the newest frame arrived
    }
}
