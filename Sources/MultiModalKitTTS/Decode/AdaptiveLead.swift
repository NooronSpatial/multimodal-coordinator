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
/// ⚠️ **D-080 CHANGED WHAT THIS TYPE SIZES FROM, and the paragraph below
/// is kept as history rather than as a description of the code.** The
/// cushion is no longer derived from a windowed length at a latest-wins
/// factor: it is the cushion the LAST reply turned out to need, measured
/// from its own decode steps (`DecodeDeficit.cushion`). The window
/// survives as `typicalLength`, which prices the first reply (AC-179).
///
/// **The cost that ruling carries, named because the review made it
/// concrete:** the measured cushion scales with the reply it came from,
/// so a short reply followed by a long one under-banks — the whipsaw the
/// window was built to prevent, back in a new form. SPEC §143a ruled this
/// ship-and-measure; INSTRUMENTS §54 then recorded the long-reply
/// measurement as VOID on this machine, so **the evidence that was meant
/// to settle it does not exist yet**. The question is open, and it is
/// open in writing rather than by omission.
///
/// The original reasoning, preserved:
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
        // NO STEP RECORD, NO CUSHION (AC-176). The whole-run numbers are
        // still here and still honest, and they are exactly what cannot
        // see a stall — sizing from them is the fault D-080 retired. A
        // margin without steps therefore teaches nothing, and the caller
        // falls back to the decoder's constant as it does on a first
        // reply.
        guard let requiredCushion = margin.requiredCushionMilliseconds else { return }
        let length = Duration.milliseconds(margin.audioMilliseconds)
        learned.withLock { memory in
            memory.lengths.append(length)
            if memory.lengths.count > Self.window {
                memory.lengths.removeFirst()
            }
            // THE RULE, AND IT IS NOW A MEASUREMENT RATHER THAN A
            // DERIVATION (D-080, F-1 = b, F-2 = all of it).
            //
            // The bank must cover the deepest point the decode ever
            // reached, and the run just measured that directly. No
            // fraction and no floor: F-2 ruled that a percentage of a
            // measured number is a guess, and D-047 already rejected an
            // insurance constant for corrupting every measurement taken
            // afterwards.
            //
            // The window of lengths is KEPT — see `typicalLength` — but
            // it no longer sizes anything. It is what AC-179 and the
            // sweep read to price a first reply, and removing it would
            // throw away the only record of what this conversation
            // sounds like.
            memory.sized = .milliseconds(requiredCushion)
        }
    }

    /// What this conversation's replies have been running, in audio time.
    ///
    /// It no longer sizes the cushion (D-080 retired that).
    ///
    /// **Nothing reads it yet, and the review was right to say so.** An
    /// earlier version of this comment claimed AC-179 and the sweep read
    /// it; neither does. AC-179 prices the first reply from the CONSTANT
    /// and §54's measured need, both of which exist without this. It is
    /// kept for one stated reason: §143a's open question — whether a
    /// cushion learned on a short reply survives a long one — can only be
    /// answered by a rule that knows how long replies here actually are,
    /// and deleting the record would mean re-earning it later. If that
    /// question is closed another way, this should go with it.
    public var typicalLength: Duration? {
        learned.withLock { memory in
            guard !memory.lengths.isEmpty else { return nil }
            return memory.lengths.reduce(Duration.zero, +) / memory.lengths.count
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
