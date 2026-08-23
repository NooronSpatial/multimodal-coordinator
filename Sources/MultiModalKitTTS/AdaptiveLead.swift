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
/// reply ends with a `DecodeMargin` carrying the steady factor it achieved.
/// This type remembers the last one and sizes the next cushion from it
/// (D-068 A).
///
/// ## What it deliberately does not do
///
/// **It does not average, and it does not keep a maximum.** The most recent
/// reply wins. A maximum would be safer against running dry and permanently
/// wrong after one thermal spike — and this phone throttles
/// (`ConservativeThermalPolicy`), so spikes are expected. Taking the latest
/// means a bad sample costs exactly one reply and then corrects itself, in
/// both directions. That is the trade, chosen deliberately and cheap to
/// reverse.
///
/// **It does not cushion the first reply of a session.** Until a reply has
/// been decoded there is nothing measured, so `target` is `nil` and the
/// caller falls back to the decoder's constant. First replies are therefore
/// still under-cushioned on a slow device; calibrating up front was the
/// alternative and it costs a load-time delay on a device where load time
/// already kills the app.
public final class AdaptiveLead: Sendable {
    /// The nominal reply this sizes for, matching the constant it replaces.
    private let replyLength: Duration
    private let learned = Mutex<Duration?>(nil)

    public init(replyLength: Duration = .seconds(6)) {
        self.replyLength = replyLength
    }

    /// `nil` until this machine has decoded something.
    public var target: Duration? { learned.withLock { $0 } }

    /// Sizes the next cushion from the reply that just finished.
    public func observe(_ margin: DecodeMargin) {
        let sized = PlaybackLead.deficit(forReplyOf: replyLength,
                                         realTimeFactor: margin.steadyRealTimeFactor)
        learned.withLock { $0 = sized }
    }

    /// Forgets what it learned — for a caller that changed the decoder and
    /// knows the old measurement no longer describes anything.
    public func forget() {
        learned.withLock { $0 = nil }
    }
}
