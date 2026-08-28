import Observation
import MultiModalKitBench

/// THE SWEEP'S OWN STATE (4j, AC-146 … AC-151).
///
/// Six properties that only the sweep reads and only the sweep writes.
/// They lived among forty others in `TranscribeModel`, so "what does the
/// sweep remember?" was a question you answered by grepping. Here it is
/// the file.
///
/// ## Why this one moved and the levers did not
///
/// Cohesion was measured before anything was cut. These six are touched
/// by three files — the sweep's methods, this model, and the Bench tab.
/// The voice levers are touched by ELEVEN, so giving them their own type
/// would have replaced one long file with a web of cross-references,
/// which is a worse thing to read than what it replaced.
///
/// `@Observable` on its own so SwiftUI still sees each property change
/// through `model.sweep.rows`; observation tracks the property actually
/// read, not the object graph above it.
@MainActor
@Observable
final class SweepState {
    var rows: [BenchRow] = []
    var running = false
    var progress = 0
    var total = 0
    /// Why the sweep would not run, or nil. AC-146: it REFUSES rather than
    /// dying, and an instrument that crashes the app is not an instrument.
    var refusal: String?
    var task: Task<Void, Never>?
}
