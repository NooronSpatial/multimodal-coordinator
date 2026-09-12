// THE VENDOR'S LOOP, DRAINED UNDER CANCELLATION (4y, AC-261, AC-264).
//
// The vendor generates in a task of its own and hands back a stream and
// that task. What frees the prefill — the KV cache the `TokenIterator`
// owns — is that task ENDING, and the review of this piece found the one
// path on which it did not: a consumer that leaves the loop with `break`
// never cancels the producer, because an `AsyncStream` fires its
// `.cancelled` termination only from a cancelled `next()` or when its
// last reference is gone, and the stream is still alive while the task
// is awaited. On that path the vendor ran to `maxTokens`, the KV cache
// grew the whole way, and the next reply queued behind it. This file is
// that loop on its own, so the cut can be PROVED with a scripted producer
// rather than argued (`MLXVendorLoopTests`).

import Foundation

enum VendorLoop {
    /// Drains `events` into `each` until the stream ends or THIS task is
    /// cancelled — a barge, a memory warning, the deadline — and returns
    /// only once the vendor's task has ended.
    ///
    /// CUT BOTH WAYS, on purpose. A cancel that lands while `next()` is
    /// parked ends the stream itself (a cancelled `next()` terminates it,
    /// and the termination cancels the vendor). A cancel that lands while
    /// the BODY is running is seen at the top of the next turn, BEFORE
    /// the next `next()` — a cut loop asks the vendor for nothing more —
    /// and leaves; and then nothing cancels the vendor unless this
    /// function does. So it does, explicitly, before the await: idempotent
    /// with the termination path, and the honest line. (A `for await`
    /// would have asked `next()` once more and let its cancellation
    /// handler terminate the stream on most runs — but only when the
    /// cancel landed before that call, never when it landed between the
    /// call's return and the check; a guarantee cannot rest on which.)
    /// Returns `true` when the generation was cut, so the caller can
    /// return the vendor's buffer pool as well.
    static func drain<Event>(
        _ events: AsyncStream<Event>, vendor: Task<Void, Never>,
        each: (Event) -> Void
    ) async -> Bool {
        var iterator = events.makeAsyncIterator()
        var cut = false
        while true {
            if Task.isCancelled { cut = true; break }
            guard let event = await iterator.next() else { break }
            each(event)
        }
        let wasCut = cut || Task.isCancelled
        // WHAT FREES THE PREFILL (AC-261, AC-264): the vendor's task is
        // cancelled here when the loop was cut — its loop breaks at its
        // next token — and AWAITED either way. That await is what makes
        // "the KV cache is gone" true when this returns: the iterator
        // that owns it is a local of that task.
        if wasCut { vendor.cancel() }
        await vendor.value
        return wasCut
    }
}
