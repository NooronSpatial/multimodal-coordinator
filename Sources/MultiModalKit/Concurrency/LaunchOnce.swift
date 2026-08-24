/// Runs an ordered list of startup steps **exactly once**, however many
/// callers ask.
///
/// ## Why this is not just a `Bool`
///
/// The demo's launch sequence is order-critical, and the order is a memory
/// bug when reversed. It loads the neural voice BEFORE the local mind,
/// because six CoreML models compile concurrently and need transient memory
/// far above the 111 MB the finished voice holds — the app was killed at
/// 1105 MB free and at 2976 MB free, and survived at 3347 (INSTRUMENTS §29).
/// The comment above it in the app reads: *"Swapping these two lines is a
/// memory bug that looks like nothing."*
///
/// Today that sequence hangs off a single screen's `.task`. Three tabs mean
/// three places that could plausibly own it, and a `.task` that runs per tab
/// runs the sequence again — which is not a slow launch, it is the kill.
///
/// So the guard cannot be a flag set at the end: two tabs appearing together
/// would both see `false` and both start. The second caller has to WAIT for
/// the first and then find the work already done — the same shape as
/// `Retirable`, one concern narrower.
public actor LaunchOnce {
    private var done = false
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var hasRun: Bool { done }

    /// Runs `steps` in order, once. Callers that arrive while it is running
    /// wait, and return when it has finished — so a caller can rely on the
    /// sequence being complete when this returns, whichever caller it was.
    public func run(_ steps: [@Sendable () async -> Void]) async {
        if done { return }
        while running {
            await withCheckedContinuation { waiters.append($0) }
            // Re-checked after the wake: the actor was released, and what we
            // were waiting for is exactly what may have changed.
            if done { return }
        }
        running = true
        for step in steps {
            await step()
        }
        // Set BEFORE waking anyone, in the same actor step, so nobody wakes
        // to a world that still says "not done".
        done = true
        running = false
        let waking = waiters
        waiters = []
        for waiter in waking { waiter.resume() }
    }
}
