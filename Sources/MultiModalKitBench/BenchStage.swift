/// THE DEVICE SEAM — everything the sweep needs from the thing it is
/// driving, and nothing about SwiftUI, CoreML or audio.
///
/// The split is deliberate: the *stage* knows how to reconfigure a phone,
/// the *sweep* knows the invariants that make a row trustworthy. Only the
/// second half is interesting, and only the second half can be tested on a
/// machine with no models — which is why it lives here and not in the app
/// (D-067 F-1 = A).
public protocol BenchStage: Sendable {
    /// Whatever the human's settings are, in a shape only the stage
    /// understands. The sweep never inspects it; it only puts it back.
    associatedtype Settings: Sendable

    /// The settings a human chose, to be restored no matter how the sweep
    /// ends (AC-151). Every lever in the demo writes to `UserDefaults` in
    /// its `didSet`, so a sweep that dies without this leaves the phone
    /// configured at whatever its last iteration set.
    func snapshot() async -> Settings
    func restore(_ settings: Settings) async

    /// AC-146. Anything that makes measuring unsafe or meaningless, in
    /// words a person can read — or `nil` to proceed.
    ///
    /// THIS USED TO ASK ONE QUESTION: "is the mind resident?" That is a real
    /// hazard — six CoreML models loading beside 2225 MB of dirty MLX
    /// weights is the kill recorded three times in INSTRUMENTS §29 — but
    /// asking about ONE hazard is how the second one gets through. It did:
    /// the first sweep run on a device with no voice model installed sailed
    /// past the gate and died inside the sampler with
    ///
    ///     Swift/FloatingPointRandom.swift:52: Fatal error:
    ///     Can't get random value with an empty range
    ///
    /// An instrument that crashes the app is not an instrument, so the
    /// question is now open-ended: the stage names any reason it has, and a
    /// new hazard becomes a new sentence rather than a new crash.
    func refusalReason() async -> String?

    /// **Returns only when the new configuration is observably up** (AC-147).
    ///
    /// This is the whole contract. `restart()` in the demo today gives no
    /// such signal — it defers teardown into a detached Task and sets
    /// `isListening` false while the microphone is still being released
    /// (SPEC §104, H-3) — so implementing this honestly is real work, and
    /// the sweep is written to make that work visible rather than to paper
    /// over it with a delay.
    func prepare(_ configuration: BenchConfiguration) async throws

    /// AC-149. Counters that survive between rows (`bargeCount`,
    /// `onsetsWhileSpeaking`) report the sum of everything before them.
    func resetCounters() async

    /// Sampled per row, after `prepare`, so it describes the machine the
    /// measurement actually ran on rather than the one the sweep started on.
    func conditions() async -> BenchConditions

    /// One utterance, timed by the stage — the sweep owns no clock.
    func measure() async throws -> BenchTiming
}
