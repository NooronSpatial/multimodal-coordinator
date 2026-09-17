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

// MARK: - the SECOND moment: heat before a generation (4y, D-107 F-2 = A)

/// D-028's one question, asked at a SECOND moment (4y, SPEC §187/2,
/// AC-260, D-107). The first moment is above: whether an optional settling
/// decode may start, governing TRANSCRIPTION only. This one is asked by a
/// mind's `openReply`, before it opens a run: may a REPLY be generated on
/// a phone this hot? It is a separate protocol with a separate default
/// because the two moments price different work — a settling decode is
/// optional comfort, a reply is the turn — and because the measured phone
/// sat at `.serious` for whole sessions (INSTRUMENTS §26): the
/// transcription default refuses there, and a reply default that did the
/// same would refuse every second turn.
///
/// THIS DOES NOT CHANGE THE TRANSCRIPTION POLICY. `ThermalPolicy` and
/// `ConservativeThermalPolicy` above are untouched by 4y, and D-028's
/// boundary still holds on this side too: a refusal is loud and typed —
/// `ReplyFailure.tooHot(state)`, thrown at the door so no run exists —
/// and the policy is never consulted for a reply already running.
///
/// Injected the way tools are (4w, F-2 = A): at the mind's construction,
/// by the app, with the shipped default when the app says nothing. The
/// coordinator never sees it (AC-265).
public protocol GenerationThermalPolicy: Sendable {
    /// Consulted at exactly one moment: `openReply`, before a run is
    /// opened. `true` = generate; `false` = the door throws
    /// `ReplyFailure.tooHot(thermal)`. `thermal` is the thermometer's
    /// state at that moment; staleness is tolerated by doctrine — the
    /// policy is a protection, never the correctness of a turn.
    func allowGeneration(thermal: ThermalState) -> Bool
}

/// The shipped default (AC-260, D-107 F-2 = A): refuse at `.critical`
/// ONLY. `.serious` generates, because the measured phone reached
/// `.serious` in every session and never recovered — refusing there is
/// refusing the product. *Rejected* by the ruling: refuse at `.serious`
/// (safer for the battery, unusable on the phone) and never refuse (what
/// the library did before 4y).
public struct DefaultGenerationThermalPolicy: GenerationThermalPolicy {
    public init() {}

    public func allowGeneration(thermal: ThermalState) -> Bool {
        thermal < .critical
    }
}
