import Synchronization

/// Lock-free single-producer / single-consumer ring buffer for audio samples.
///
/// RED STUB — public surface only; the real behavior lands with the green
/// commit for the ring test suite (SPEC AC-1…AC-5).
public enum AudioRing {
    /// Creates one connected pair of handles. The contract (SPSC): exactly
    /// ONE producer and ONE consumer, each used from one side only.
    public static func create(minimumCapacity: Int) -> (producer: AudioRingProducer, consumer: AudioRingConsumer) {
        let storage = RingStorage(minimumCapacity: minimumCapacity)
        return (AudioRingProducer(storage: storage), AudioRingConsumer(storage: storage))
    }
}

public final class AudioRingProducer: Sendable {
    let storage: RingStorage

    init(storage: RingStorage) {
        self.storage = storage
    }

    /// Ring capacity in frames (rounded up to a power of two).
    public var capacity: Int { storage.capacity }

    /// HOT PATH — will be safe to call from the real-time audio thread.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        // red stub: does nothing
    }
}

public final class AudioRingConsumer: Sendable {
    let storage: RingStorage

    init(storage: RingStorage) {
        self.storage = storage
    }

    public struct ReadResult: Sendable, Equatable {
        public let framesRead: Int
        public let framesDropped: Int

        public init(framesRead: Int, framesDropped: Int) {
            self.framesRead = framesRead
            self.framesDropped = framesDropped
        }
    }

    /// Ring capacity in frames (rounded up to a power of two).
    public var capacity: Int { storage.capacity }

    /// Total frames ever dropped (observability seam, SPEC AC-4).
    public var totalDropped: Int { storage.dropped.load(ordering: .relaxed) }

    /// COOL PATH — the pump's read. Fills `destination` with the oldest
    /// still-valid frames, skipping (and counting) anything overwritten.
    public func read(into destination: UnsafeMutableBufferPointer<Float>) -> ReadResult {
        // red stub: reads nothing
        ReadResult(framesRead: 0, framesDropped: 0)
    }
}

/// The one deliberately unsafe island of the package — see DECISIONS D-007.
final class RingStorage: @unchecked Sendable {
    let capacity: Int
    let mask: Int
    let slab: UnsafeMutablePointer<Float>

    /// The ONE value that crosses the thread boundary. Written by the
    /// producer only; read by both sides. Monotonic — never wraps.
    let head: Atomic<Int>

    /// Padding so `head` and `dropped` sit on different cache lines —
    /// the hot core and the cool core must not fight over one 64-byte line.
    private let _padding: (Int64, Int64, Int64, Int64, Int64, Int64, Int64) = (0, 0, 0, 0, 0, 0, 0)

    /// Dropped-frame statistics. Written by the consumer only.
    let dropped: Atomic<Int>

    /// Consumer-local read position. NOT atomic on purpose: by the SPSC
    /// contract only the single consumer ever touches it.
    var tail: Int = 0

    init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0, "capacity must be positive")
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        slab = .allocate(capacity: cap)
        slab.initialize(repeating: 0, count: cap)
        head = Atomic(0)
        dropped = Atomic(0)
    }

    deinit {
        slab.deallocate()
    }
}
