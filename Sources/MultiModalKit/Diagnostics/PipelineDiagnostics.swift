/// What the pipeline can tell you about how it feels (AC-48, D-027).
public enum HealthEvent: Sendable, Equatable {
    /// The device's thermal state — the baseline on start, then every change.
    case thermal(ThermalState)
    /// The ring lost sound; mirrored from the pump's timeline (D-010).
    case ringDropped(frames: Int, at: AudioTime)
    /// A listener read too slowly and its buffer dropped events (D-012).
    case listenerFellBehind(listenerID: Int, totalDropped: Int)
    /// How many batch decodes are still thinking (D-024) — on every change.
    case settlingDecodes(count: Int)
}

/// The injected diagnostics seam (D-026 F5): owned by the consumer, handed
/// to the pieces like a clock. Components REPORT here; consumers LISTEN
/// here; policy lives with whoever is listening — never in the pipeline
/// (D-027: mechanism, not policy).
///
/// RED STUB — public surface only; behavior lands with the green commit.
public final class PipelineDiagnostics: Sendable {
    let thermal: any ThermalStateProviding

    public init(
        thermal: any ThermalStateProviding = SystemThermalProvider(),
        healthBufferCapacity: Int = Broadcast<HealthEvent>.defaultBufferCapacity
    ) {
        self.thermal = thermal
    }

    /// Adds a health listener (house rules: bounded, drop-oldest, no replay).
    public func health() -> Broadcast<HealthEvent>.Listener {
        Broadcast<HealthEvent>.Listener(id: 0, events: AsyncStream { $0.finish() })
    }

    /// Publishes the thermal baseline, then every transition, until the
    /// provider's stream ends or `stop()` is called.
    public func run() async {}

    /// Ends every health listener's stream. Safe to call more than once.
    public func stop() {}

    // MARK: - reporting hooks (called by the pipeline's components — and by
    // any stage a consumer builds on top; reporting is not a privilege)

    public func noteRingDrop(frames: Int, at: AudioTime) {}

    /// Published only when the count actually changes.
    public func noteSettlingDecodes(count: Int) {}

    /// Wired into a component's Broadcast so slow listeners become visible.
    public func noteListenerLoss(listenerID: Int, totalDropped: Int) {}
}
