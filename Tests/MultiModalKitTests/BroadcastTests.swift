import Testing
import MultiModalKit

/// RED SUITE for the multicast seam (D-008, D-012).
///
/// Three promises are tested here and nothing else: every listener sees the
/// same sequence, a slow listener loses the OLDEST events and knows how many,
/// and a late listener gets no replay — because these are moments, not state.
@Suite(.timeLimit(.minutes(1)))
struct BroadcastTests {

    static func collect(_ stream: AsyncStream<Int>, cap: Int = 200) async -> [Int] {
        var out: [Int] = []
        for await value in stream {
            out.append(value)
            if out.count >= cap { break }
        }
        return out
    }

    @Test("Every listener receives the same sequence")
    func everyListenerReceivesTheSameSequence() async {
        let broadcast = Broadcast<Int>()
        let first = broadcast.listen()
        let second = broadcast.listen()

        for value in 1...3 { broadcast.publish(value) }
        broadcast.finish()

        let a = await Self.collect(first.events)
        let b = await Self.collect(second.events)
        #expect(a == [1, 2, 3])
        #expect(b == [1, 2, 3])
    }

    @Test("A late listener hears only what comes next — no replay")
    func lateListenerHearsOnlyWhatComesNext() async {
        let broadcast = Broadcast<Int>()

        broadcast.publish(1)              // nobody is listening yet
        let late = broadcast.listen()
        broadcast.publish(2)
        broadcast.finish()

        let heard = await Self.collect(late.events)
        #expect(heard == [2], "a replayed event would be a lie about when it happened")
    }

    @Test("A slow listener loses the oldest events, and the loss is counted")
    func slowListenerDropsOldestAndCountsThem() async {
        let broadcast = Broadcast<Int>(bufferCapacity: 4)
        let slow = broadcast.listen()

        for value in 1...6 { broadcast.publish(value) }   // two more than it can hold
        broadcast.finish()

        let heard = await Self.collect(slow.events)
        #expect(heard == [3, 4, 5, 6], "the OLDEST events must be the ones dropped")
        #expect(broadcast.droppedEvents(for: slow.id) == 2)
    }

    @Test("A slow listener never affects what another listener sees")
    func slowListenerDoesNotDisturbTheOthers() async {
        let broadcast = Broadcast<Int>(bufferCapacity: 4)
        let slow = broadcast.listen()
        let fast = broadcast.listen()

        for value in 1...6 { broadcast.publish(value) }
        broadcast.finish()

        // The fast listener reads everything it was given; the slow one lost two.
        let fastHeard = await Self.collect(fast.events)
        let slowHeard = await Self.collect(slow.events)
        #expect(fastHeard == [3, 4, 5, 6])
        #expect(slowHeard == fastHeard)
        #expect(broadcast.droppedEvents(for: fast.id) == broadcast.droppedEvents(for: slow.id))
    }

    @Test("finish() ends every listener's stream, and is safe to call twice")
    func finishEndsEveryListenerStream() async {
        let broadcast = Broadcast<Int>()
        let first = broadcast.listen()
        let second = broadcast.listen()

        broadcast.publish(7)
        broadcast.finish()
        broadcast.finish()

        #expect(await Self.collect(first.events) == [7])
        #expect(await Self.collect(second.events) == [7])
        #expect(broadcast.listenerCount == 0)
    }

    @Test("Listening after finish gets a stream that is already over")
    func listenAfterFinishGetsAnAlreadyFinishedStream() async {
        let broadcast = Broadcast<Int>()
        broadcast.finish()

        let late = broadcast.listen()
        #expect(await Self.collect(late.events) == [])
    }

    @Test("Two listeners are counted while they exist")
    func listenersAreCounted() {
        let broadcast = Broadcast<Int>()
        #expect(broadcast.listenerCount == 0)
        _ = broadcast.listen()
        _ = broadcast.listen()
        #expect(broadcast.listenerCount == 2)
    }
}
