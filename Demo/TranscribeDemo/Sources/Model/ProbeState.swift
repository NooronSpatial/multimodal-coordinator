import Observation
import MultiModalKit
import MultiModalKitBench

/// THE PRESSURE PROBE'S OWN STATE (4i/4n).
///
/// What the probe remembers while it runs: the trace it is writing, the
/// sampler's flag, how many lines the last phase produced, and the
/// monitor it holds. Four properties, touched by the probe's methods and
/// the Bench tab, and nothing else.
///
/// Kept together because AC-170's rule lives across two of them: a phase
/// that wrote ZERO lines measured nothing, and the trace must say so
/// rather than print `survived: yes` over it. That rule is easier to
/// keep when the counter and the trace are in the same file.
@MainActor
@Observable
final class ProbeState {
    var lines: [String] = []

    /// SAMPLES THE DESCENT while something expensive loads.
    ///
    /// The steady footprint is not what kills: TTSKit reports "Loading 6
    /// CoreML models concurrently", and six simultaneous compiles need
    /// transient memory far above what the finished models hold. That
    /// peak is invisible from outside — the app simply stops.
    ///
    /// So this writes a reading every 250 ms, flushed, while the load
    /// runs. If jetsam takes the process, the LAST line is how close it
    /// got before dying, which is the number nothing else can give us.
    var samplerBusy = false
    /// How many lines the LAST sampled phase actually wrote. Zero after a
    /// phase means the load returned inside one sample interval — nothing
    /// was watched, and AC-170 says the trace must say so instead of
    /// blessing it. The first field run printed `survived: yes` around
    /// exactly that, and only a human comparing four identical numbers by
    /// eye caught it.
    var lastPhaseSamples = 0

    /// The kernel's own alarm, recorded into the same trace. AC-139
    /// showed both in-process numbers blind to a load that kills, because
    /// CoreML prepares models in system daemons — so this is the only
    /// instrument positioned to see it (INSTRUMENTS §30).
    var monitor: MemoryPressureMonitor?
}
