// THE WARM'S END, AS AN EVENT (5b, AC-312; D-116 F-7 A, D-124 F-21 B).
//
//     prewarm() ── asked ──▶ a load begins ──▶ it ends ── resident ──▶ whenWarm() == true
//                                                     └─ not ─────▶ whenWarm() == false
//     resident already ─▶ true at once · nothing asked, nothing loading ─▶ false at once
//     cancelled ─▶ at once, with what is true then
//
// The diet app waited for a warm by polling `isResident` every 200 ms, up
// to 600 times; this repository's demo started a warm and never learned
// its end. The question both ask is "may I stop showing the spinner?" —
// one await, and it must always come back: a warm that fails answers
// `false` (F-21 B), never a wait that lasts until the app gives up.

import Synchronization

/// Watches one model's warm, and answers `whenWarm()`.
///
/// The model reports into it at four points — a warm asked for, a warm
/// over, a load begun, a load ended — and on a retire. It starts no work
/// and decides nothing about loading: it only knows whether anything is
/// still on its way, and whether the weights arrived.
///
/// A `Mutex` component, not actor state (§4.1's small exception, and its
/// proof): a waiter's CANCEL must answer that waiter, and a cancel
/// handler runs wherever the cancel came from — it cannot hop to the
/// model's actor and wait its turn behind a 2 GB load. So every fact and
/// every waiter lives behind one lock; a waiter is taken out under the
/// lock and resumed OUTSIDE it (lock rule 2), so whichever path takes it
/// — the answer or the cancel — answers it exactly once.
final class WarmWatch: Sendable {
    private struct State {
        /// Warms asked for and not yet over. Raised SYNCHRONOUSLY by
        /// `MLXReplyGenerator.prewarm()`, before its hop to the model, so
        /// a `whenWarm()` asked right after `prewarm()` cannot find
        /// "nothing loading" in the gap between the two.
        var asked = 0
        /// Loads in flight — a turn's own load counts too: its end is a
        /// warm's end as much as a prewarm's is.
        var loading = 0
        /// The weights, as the last load or retire left them.
        var resident = false
        var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        var nextWaiter = 0

        /// Something is still on its way.
        var warming: Bool { asked > 0 || loading > 0 }
    }

    private let state = Mutex(State())

    /// Every waiter that registered, ever — the EVENT a test waits on
    /// before it ends a load, never a guess about time.
    let waitersSeen = ThresholdWatch()

    // MARK: what the model reports

    /// A warm was asked for (`prewarm()`, before its hop).
    func asked() { state.withLock { $0.asked += 1 } }

    /// That warm is over — however it ended, including never starting
    /// because another was already running.
    func askEnded() { settle { $0.asked -= 1 } }

    /// A load began (`ensureModelLoaded()`).
    func loadBegan() { state.withLock { $0.loading += 1 } }

    /// That load ended, and whether the weights are resident after it.
    func loadEnded(resident: Bool) {
        settle {
            $0.loading -= 1
            $0.resident = resident
        }
    }

    /// The weights were let go (`retire()`).
    func retired() { settle { $0.resident = false } }

    /// Whether a warm is asked for or a load is in flight.
    var isWarming: Bool { state.withLock { $0.warming } }

    // MARK: the answer

    /// `true` when the weights are resident; `false` when nothing is on its
    /// way any more. At once when either is already so; otherwise when the
    /// load or warm in flight ends. Cancelled, at once with what is true
    /// then. Starts no work.
    func whenWarm() async -> Bool {
        let ticket = state.withLock { state -> Int in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // ONE lock step: answer now, or wait. A cancel that landed
                // before this step found no waiter to answer, so it is
                // read here too — or that waiter would wait for the load.
                let now = state.withLock { state -> Bool? in
                    if state.resident { return true }
                    if !state.warming || Task.isCancelled { return state.resident }
                    state.waiters[ticket] = continuation
                    return nil
                }
                if let now {
                    continuation.resume(returning: now)
                } else {
                    waitersSeen.increment()
                }
            }
        } onCancel: {
            let (waiter, now) = state.withLock { state in
                (state.waiters.removeValue(forKey: ticket), state.resident)
            }
            waiter?.resume(returning: now)
        }
    }

    /// Applies a change, and when there is now something to say — the
    /// weights are resident, or nothing is on its way — answers every
    /// waiter with it, outside the lock.
    private func settle(_ change: (inout State) -> Void) {
        let (answer, woken) = state.withLock { state -> (Bool, [CheckedContinuation<Bool, Never>]) in
            change(&state)
            guard state.resident || !state.warming else { return (false, []) }
            defer { state.waiters.removeAll() }
            return (state.resident, Array(state.waiters.values))
        }
        for waiter in woken { waiter.resume(returning: answer) }
    }
}
