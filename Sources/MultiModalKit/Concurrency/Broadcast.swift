import Synchronization

/// One publisher, many listeners (D-008).
///
/// Every listener gets its own stream and sees the same sequence. Three rules
/// come from D-012 and they are the whole design:
///
/// 1. **Bounded.** Each listener's buffer holds a fixed number of events.
/// 2. **Drop-oldest, and counted.** When a slow listener's buffer is full the
///    OLDEST event is dropped and that listener's `droppedEvents` goes up.
///    Memory is capped; the loss is never hidden.
/// 3. **No replay.** A listener that arrives late hears what happens from now
///    on. These are moments, not state — replaying "speech started" to
///    somebody who joined ten seconds later would be a lie.
///
/// **The two lock rules**, which this type exists to respect:
/// never hold the lock across a suspension point, and never resume or finish a
/// continuation while holding it. A continuation's `onTermination` can run on
/// the spot and re-enter the lock — that is a silent, instant deadlock. So the
/// pattern here is always: decide under the lock, take a snapshot, act outside.
public final class Broadcast<Element: Sendable>: Sendable {
    /// One listener's handle: its own stream, and an id to ask about its losses.
    public struct Listener: Sendable {
        public let id: Int
        public let events: AsyncStream<Element>

        public init(id: Int, events: AsyncStream<Element>) {
            self.id = id
            self.events = events
        }
    }

    /// Events a single listener may fall behind by before the oldest is dropped.
    public static var defaultBufferCapacity: Int { 64 }

    private struct State {
        var nextID = 0
        var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
        var dropped: [Int: Int] = [:]
        var isFinished = false
    }

    let bufferCapacity: Int
    private let state = Mutex(State())

    public init(bufferCapacity: Int = Broadcast.defaultBufferCapacity) {
        self.bufferCapacity = bufferCapacity
    }

    /// Adds a listener. It receives everything published from now on.
    public func listen() -> Listener {
        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            state.dropped[id] = 0
            return id
        }

        // `.bufferingNewest` IS the drop-oldest policy: when the buffer is
        // full the oldest element is discarded and `yield` reports it, which
        // is how the loss gets counted instead of vanishing.
        var handle: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: .bufferingNewest(bufferCapacity)) {
            handle = $0
        }
        let continuation = handle!

        let arrivedTooLate = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.continuations[id] = continuation
            return false
        }

        // Outside the lock — always (rule 2).
        if arrivedTooLate { continuation.finish() }
        continuation.onTermination = { [weak self] _ in
            self?.forget(id)
        }

        return Listener(id: id, events: stream)
    }

    /// Sends one event to every current listener. Never blocks, never waits —
    /// a slow listener costs itself an event, never the pump a millisecond.
    public func publish(_ element: Element) {
        let targets = state.withLock { Array($0.continuations) }   // snapshot under the lock

        var overflowed: [Int] = []
        for (id, continuation) in targets {                        // yield outside it
            if case .dropped = continuation.yield(element) {
                overflowed.append(id)
            }
        }

        guard !overflowed.isEmpty else { return }
        state.withLock { state in
            for id in overflowed { state.dropped[id, default: 0] += 1 }
        }
    }

    /// Ends every listener's stream. Safe to call more than once.
    public func finish() {
        let survivors = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.isFinished = true
            let all = Array(state.continuations.values)
            state.continuations.removeAll()
            return all
        }
        for continuation in survivors { continuation.finish() }     // outside the lock
    }

    /// How many events this listener missed because it read too slowly.
    public func droppedEvents(for id: Int) -> Int {
        state.withLock { $0.dropped[id] ?? 0 }
    }

    /// Listeners currently attached.
    public var listenerCount: Int {
        state.withLock { $0.continuations.count }
    }

    /// Called when a listener's stream dies — cancelled, finished, or simply
    /// dropped by its owner. A dead listener must not be published to forever.
    private func forget(_ id: Int) {
        state.withLock { $0.continuations[id] = nil }
    }
}
