import Synchronization

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
public final class PipelineDiagnostics: Sendable {
    let thermal: any ThermalStateProviding
    /// The pipeline's marks for Instruments (AC-45). Components reach it
    /// through the seam; when no diagnostics is injected, no mark exists.
    public let signposts = PipelineSignposter()
    private let broadcast: Broadcast<HealthEvent>
    /// The last settling count published — the dedupe memory. A reference
    /// box because Mutex is non-copyable.
    private final class LastCount: Sendable { let store = Mutex<Int?>(nil) }
    private let lastSettling = LastCount()

    public init(
        thermal: any ThermalStateProviding = SystemThermalProvider(),
        healthBufferCapacity: Int = Broadcast<HealthEvent>.defaultBufferCapacity
    ) {
        self.thermal = thermal
        self.broadcast = Broadcast(bufferCapacity: healthBufferCapacity)
    }

    /// Adds a health listener (house rules: bounded, drop-oldest, no replay).
    public func health() -> Broadcast<HealthEvent>.Listener {
        broadcast.listen()
    }

    /// Publishes the thermal BASELINE first (ruled 08-11: silence must be
    /// meaningful — a listener learns "now", not "eventually"), then every
    /// transition, until the provider's stream ends or the task is cancelled.
    public func run() async {
        broadcast.publish(.thermal(thermal.current))
        for await state in thermal.transitions() {
            broadcast.publish(.thermal(state))
        }
    }

    /// Ends every health listener's stream. Safe to call more than once;
    /// reports arriving afterwards fall on finished streams and vanish.
    public func stop() {
        broadcast.finish()
    }

    // MARK: - reporting hooks (called by the pipeline's components — and by
    // any stage a consumer builds on top; reporting is not a privilege)

    public func noteRingDrop(frames: Int, at: AudioTime) {
        broadcast.publish(.ringDropped(frames: frames, at: at))
    }

    /// Published only when the count actually changes.
    public func noteSettlingDecodes(count: Int) {
        let changed = lastSettling.store.withLock { last -> Bool in
            guard last != count else { return false }
            last = count
            return true
        }
        if changed { broadcast.publish(.settlingDecodes(count: count)) }
    }

    /// Wired into a component's Broadcast so slow listeners become visible.
    public func noteListenerLoss(listenerID: Int, totalDropped: Int) {
        broadcast.publish(.listenerFellBehind(listenerID: listenerID, totalDropped: totalDropped))
    }
}
