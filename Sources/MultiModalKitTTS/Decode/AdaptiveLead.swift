import MultiModalKit
import Synchronization

/// The cushion, learned from the machine that is actually decoding.
///
/// ## Why a constant was never going to be right
///
/// `PlaybackLead.deficit(forReplyOf:realTimeFactor:)` is the rule, and it is
/// correct. What was wrong was its input: `measuredRealTimeFactor(for:)`
/// returns numbers measured on one Mac — 0.752 for `.fused`, 1.066 for
/// `.stepped`. The iPhone's neural decode was measured at **1.21**
/// (INSTRUMENTS §22). On a six-second reply that is the difference between
/// a 396 ms cushion and the ~1260 ms the phone actually needs, so the phone
/// runs dry mid-reply and the ear hears it as "still slow".
///
/// The fix is not a better constant. There is no constant: the right value
/// is a property of the machine, and the machine is already telling us. Every
/// reply ends with a `DecodeMargin` carrying the steady factor it achieved
/// and the length it actually spoke; this type learns from both (D-068 A,
/// then D-073).
///
/// ## What it deliberately does not do
///
/// **The RTF is latest-wins; the LENGTH is windowed — two estimators, on
/// purpose (D-073).** The RTF is a property of the MACHINE: it drifts with
/// thermals, this phone throttles (`ConservativeThermalPolicy`), and the
/// newest sample is the best estimate of now — a maximum would stay
/// permanently wrong after one spike. The length is a property of the
/// CONVERSATION: it swings turn to turn, so a single latest sample would
/// whipsaw — one short "yes" would shrink the cushion right before the
/// next long answer, re-creating §48 on every alternation. The typical
/// length is the mean of the last four replies instead: it adapts within
/// a few turns and dilutes one outlier fourfold. Mean rather than median
/// because the outlier IS the signal this fix exists for — a median would
/// discard exactly the long replies that go weird.
///
/// The first version of this type sized every cushion for a NOMINAL six
/// seconds, discarding the `audioMilliseconds` its margins already
/// carried. §48 recorded the consequence: the formula right, the input
/// wrong, and long replies outran the bank — *"the weirdness or let us
/// say slow still there"*.
///
/// **It does not cushion the first reply of a session.** Until a reply has
/// been decoded there is nothing measured, so `target` is `nil` and the
/// caller falls back to the decoder's constant. First replies are therefore
/// still under-cushioned on a slow device; calibrating up front was the
/// alternative and it costs a load-time delay on a device where load time
/// already kills the app.
public final class AdaptiveLead: Sendable {
    private struct Memory {
        /// The last few reply lengths, oldest first. Never more than
        /// `window` of them.
        var lengths: [Duration] = []
        /// The cushion sized at the last observation.
        var sized: Duration?
    }

    /// D-073 F-1 = A. Four: small enough to adapt within a few turns,
    /// large enough that one outlier is diluted fourfold.
    private static let window = 4
    private let learned = Mutex<Memory>(Memory())

    public init() {}

    /// `nil` until this machine has decoded something.
    public var target: Duration? { learned.withLock { $0.sized } }

    /// Sizes the next cushion from the reply that just finished: its OWN
    /// length joins the window, and the cushion is the deficit of the
    /// window's mean at the factor this reply just measured.
    ///
    /// ONLY FINISHED REPLIES TEACH. A failed decode reports a margin too,
    /// and its numbers are honest — but its length is however far the run
    /// got before the throw, not a reply the conversation produced. The 4m
    /// review walked the chain: one transient failure at 2 s into a 20 s
    /// answer would teach the window "replies are short" and under-bank the
    /// next four cushions — the exact §48 direction. Its RTF is discarded
    /// with it: rare failures do not justify splitting the feeding rule,
    /// and the next finished reply refreshes the factor anyway.
    public func observe(_ margin: DecodeMargin) {
        guard margin.completed else { return }
        let length = Duration.milliseconds(margin.audioMilliseconds)
        learned.withLock { memory in
            memory.lengths.append(length)
            if memory.lengths.count > Self.window {
                memory.lengths.removeFirst()
            }
            let total = memory.lengths.reduce(Duration.zero, +)
            let typical = total / memory.lengths.count
            memory.sized = PlaybackLead.deficit(
                forReplyOf: typical,
                realTimeFactor: margin.steadyRealTimeFactor)
        }
    }

    /// Forgets what it learned — for a caller that changed the decoder and
    /// knows the old measurements no longer describe anything. The WINDOW
    /// empties too: a length spoken by a retired decoder must not size a
    /// cushion for its replacement.
    public func forget() {
        learned.withLock { $0 = Memory() }
    }
}
