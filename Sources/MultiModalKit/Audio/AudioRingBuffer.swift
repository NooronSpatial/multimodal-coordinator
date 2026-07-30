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

    /// HOT PATH — safe to call from the real-time audio thread.
    ///
    /// Copies `samples` into the ring and publishes them by moving `head`.
    /// Obeys the iron laws: no locks, no allocation, no waiting — only a
    /// bounds check, one or two memory copies, and one atomic store.
    /// If the chunk is larger than the whole ring (should never happen with
    /// real audio chunks; asserted in debug), only its newest part is kept.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        assert(samples.count <= storage.capacity,
               "audio chunk larger than the whole ring — capacity is misconfigured")
        let n = min(samples.count, storage.capacity)
        let source = base + (samples.count - n)          // newest part wins

        // Producer owns `head`; relaxed load of our own counter is fine.
        let h = storage.head.load(ordering: .relaxed)
        let start = h & storage.mask
        let firstPart = min(n, storage.capacity - start)
        (storage.slab + start).update(from: source, count: firstPart)
        if n > firstPart {                               // wrap around the seam
            storage.slab.update(from: source + firstPart, count: n - firstPart)
        }
        // Publish: "the bytes are ready." Anyone who acquires `head` after
        // this store is guaranteed to see the copied samples.
        storage.head.store(h + n, ordering: .releasing)
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
    ///
    /// The overrun story: the producer NEVER waits and never touches `tail` —
    /// if the reader falls behind, the producer simply writes over the oldest
    /// frames. This read therefore (1) clamps its start to the newest
    /// ring-full of data, counting everything it had to skip as dropped, and
    /// (2) VALIDATES after copying: if the producer lapped us during the
    /// copy, the copied bytes are suspect — they are counted as dropped and
    /// the read retries once from a fresh position. The buffer may drop, but
    /// it may never lie.
    public func read(into destination: UnsafeMutableBufferPointer<Float>) -> ReadResult {
        guard let dst = destination.baseAddress, destination.count > 0 else {
            return ReadResult(framesRead: 0, framesDropped: 0)
        }
        var totalDroppedNow = 0
        for _ in 0..<2 {                                  // one honest retry, never a spin
            // Acquire pairs with the producer's release: after this load we
            // are guaranteed to see every byte published up to `h`.
            let h = storage.head.load(ordering: .acquiring)
            var start = storage.tail
            if h - start > storage.capacity {             // we were lapped while idle
                let lost = (h - storage.capacity) - start
                totalDroppedNow += lost
                start = h - storage.capacity
            }
            let available = h - start
            if available == 0 {
                storage.tail = start
                break
            }
            let n = min(available, destination.count)
            let s = start & storage.mask
            let firstPart = min(n, storage.capacity - s)
            dst.update(from: storage.slab + s, count: firstPart)
            if n > firstPart {                            // wrap around the seam
                (dst + firstPart).update(from: storage.slab, count: n - firstPart)
            }
            // Validate: did the producer lap into what we just copied?
            let h2 = storage.head.load(ordering: .acquiring)
            if h2 - start <= storage.capacity {           // clean copy
                storage.tail = start + n
                if totalDroppedNow > 0 {
                    storage.dropped.wrappingAdd(totalDroppedNow, ordering: .relaxed)
                }
                return ReadResult(framesRead: n, framesDropped: totalDroppedNow)
            }
            // Torn copy: treat it as dropped and retry once from fresh data.
            totalDroppedNow += n
            storage.tail = start + n
        }
        if totalDroppedNow > 0 {
            storage.dropped.wrappingAdd(totalDroppedNow, ordering: .relaxed)
        }
        return ReadResult(framesRead: 0, framesDropped: totalDroppedNow)
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
