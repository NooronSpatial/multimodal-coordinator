import Foundation

/// WHEN IT IS SAFE TO START SPEAKING (SPEC AC-107, D-046 = A).
///
/// A renderer that plays the first buffer the moment it arrives has no
/// margin. If the decoder makes audio more slowly than the ear drinks
/// it, the player empties and the speech gaps. AC-102 measured that on
/// this project's own neural mouth: a real-time factor of 1.09–1.23, and
/// a long sentence whose total was decode wall time rather than
/// first-audio plus audio. Every buffer arrived ~10 ms late, from the
/// very first one, because playback began with **zero lead**.
///
/// ```
///  no lead   decode ├──90ms──┤──92ms──┤──88ms──┤
///            play   [ 80ms ][dry][ 80ms ][dry][ 80ms ]
///
///  with lead decode ├──90ms──┤──92ms──┤──88ms──┤
///            play          ↑ start here, already holding a cushion
///                          [ 80ms ][ 80ms ][ 80ms ]   no dry spells
/// ```
///
/// The rule is small enough to be pure, so it is: no clock, no player,
/// no model, no audio. Time lives with the caller — the same law the
/// VAD follows. That is what lets the rule be proven on any machine,
/// including one with no speaker and no 1.1 GB of weights on disk.
///
/// **It lives in the core, beside `SpeechPhraser`,** because it knows
/// nothing about TTS: it is a timing rule for any streaming render path,
/// and the next one (a streamed voice over an LLM) will want it too.
///
/// THE PROMISE THAT MATTERS MOST is not "wait for the cushion" — it is
/// that waiting can never become waiting forever. A four-word reply is
/// shorter than any useful lead and always will be, so `noMoreAudio()`
/// releases whatever is held. A rule that waited for audio nobody will
/// ever send would hang the turn, which is precisely the failure the
/// synthesis conformance kit's liveness promise exists to catch — and
/// this catches it a layer earlier, without hardware.
public struct PlaybackLead: Sendable {

    /// How much audio to hold before the first sound. `.zero` means
    /// "start on the first buffer", which is the behaviour AC-102
    /// measured — kept reachable so that number can be REPRODUCED
    /// against this code rather than remembered from a table.
    public let target: Duration

    /// What is being held right now. Read-only to callers: the whole
    /// point of the type is that the arithmetic happens in one place.
    public private(set) var queuedAudio: Duration = .zero

    /// Whether the first sound has been released.
    public private(set) var hasStarted = false

    /// Latched by `abandon()`. A barged reply must not start, and must
    /// not report a start, however much decoded audio is still in
    /// flight behind it.
    private var abandoned = false

    public init(target: Duration) {
        self.target = target
    }

    /// Hands more decoded audio to the rule.
    ///
    /// - Returns: `true` EXACTLY ONCE, on the call that releases the
    ///   first sound. The caller uses that `true` to touch the player,
    ///   so a second `true` would be a double-start — a bug only
    ///   hardware would show.
    public mutating func queue(_ audio: Duration) -> Bool {
        // An empty step is not progress. Without this, a decoder that
        // emits a zero-sample step would "reach" a zero target and start
        // a player holding nothing.
        guard audio > .zero, !abandoned, !hasStarted else { return false }
        queuedAudio += audio
        guard queuedAudio >= target else { return false }
        hasStarted = true
        return true
    }

    /// The reply is complete: no more audio will ever arrive.
    ///
    /// - Returns: `true` if this releases a first sound that the target
    ///   alone would have held forever. A reply with nothing in it
    ///   returns `false` and starts nothing — silence is a valid reply.
    public mutating func noMoreAudio() -> Bool {
        guard !abandoned, !hasStarted, queuedAudio > .zero else { return false }
        hasStarted = true
        return true
    }

    /// The reply was abandoned — barged, cancelled, failed. Nothing
    /// starts after this, ever.
    public mutating func abandon() {
        abandoned = true
    }

    /// THE SIZING RULE, kept next to the rule it sizes.
    ///
    /// A decoder running at `realTimeFactor` R takes `length × R` to
    /// make `length` of audio, so over a whole reply it falls behind by
    /// `length × (R − 1)`. That shortfall is what the lead has to have
    /// already banked. Below 1.0 the decoder runs ahead of the speaker
    /// and no lead is needed at all.
    ///
    /// The honest limit, stated here because it is a property of the
    /// arithmetic and not of this code: a FIXED lead only buys gapless
    /// playback up to the reply length it was sized for. While R stays
    /// above 1.0, a long enough reply drains any cushion. Lowering R is
    /// the only fix that has no ceiling — which is why D-046 ruled B
    /// first and A regardless.
    public static func deficit(forReplyOf reply: Duration,
                               realTimeFactor: Double) -> Duration {
        guard realTimeFactor > 1.0 else { return .zero }
        let replyMS = Double(reply.components.seconds) * 1000
            + Double(reply.components.attoseconds) * 1e-15
        let shortfall = replyMS * (realTimeFactor - 1.0)
        return .milliseconds(Int(shortfall.rounded()))
    }
}
