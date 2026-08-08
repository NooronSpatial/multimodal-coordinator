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
/// The lock rules for this component (learned the hard way): never hold the
/// lock across a suspension point, and never finish a continuation while
/// holding it — snapshot under the lock, act outside.
///
/// RED STUB — public surface only; behavior lands with the green commit.
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

    let bufferCapacity: Int

    public init(bufferCapacity: Int = Broadcast.defaultBufferCapacity) {
        self.bufferCapacity = bufferCapacity
    }

    /// Adds a listener. It receives everything published from now on.
    public func listen() -> Listener {
        Listener(id: 0, events: AsyncStream { $0.finish() })
    }

    /// Sends one event to every current listener. Never blocks, never waits.
    public func publish(_ element: Element) {
        _ = element
    }

    /// Ends every listener's stream. Safe to call more than once.
    public func finish() {}

    /// How many events this listener missed because it read too slowly.
    public func droppedEvents(for id: Int) -> Int {
        _ = id
        return 0
    }

    /// Listeners currently attached.
    public var listenerCount: Int { 0 }
}
