/// The D-028 seam: what to do about heat, injected like the clock.
///
/// D-027 ruled that the pipeline reports and the CONSUMER decides — and
/// deferred an opt-in policy until numbers existed. They exist
/// (INSTRUMENTS.md), and they reveal exactly one lever: the settling
/// decode — optional comfort work (D-024), the only measured compute worth
/// declining. So the seam is one question, asked at one moment.
///
/// The boundary D-027 keeps: a policy can only decline OPTIONAL work. It is
/// never consulted for the live utterance, cannot stop listening, cannot
/// cancel active runs. Refusals are loud: the utterance surfaces
/// `.failed(.declinedUnderThermalPressure)`, and one `HealthEvent` records
/// each refusal.
public protocol ThermalPolicy: Sendable {
    /// Consulted at exactly one moment (AC-55): when a whole-utterance
    /// run's decode is about to move to the settling table because new
    /// speech began. `true` = the decode keeps its ticket; `false` = the
    /// run is retired instead — cancelled (an optimisation; the dead
    /// ticket is the guarantee), its loss announced.
    ///
    /// `thermal` is the state at the moment of the decision; staleness is
    /// tolerated by doctrine — the policy is an optimization, never
    /// correctness. `activeSettlingDecodes` counts decodes already
    /// settling, so a policy can also cap concurrency alone.
    func allowSettlingDecode(thermal: ThermalState, activeSettlingDecodes: Int) -> Bool
}

/// The shipped default (AC-57), priced by the field numbers: settling
/// decodes are 110 ms Neural-Engine bursts that pile up ×2–3 under
/// contention — worth declining on a hot device, invisible on a cool one.
///
/// Dormant below `.serious` by construction: on a device that never runs
/// hot, this policy never changes anything.
public struct ConservativeThermalPolicy: ThermalPolicy {
    public init() {}

    public func allowSettlingDecode(thermal: ThermalState, activeSettlingDecodes: Int) -> Bool {
        thermal < .serious
    }
}
