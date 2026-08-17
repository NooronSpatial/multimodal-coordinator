import Foundation

/// WHERE TO PUT THE GATE, computed instead of guessed (AC-97).
///
/// The gate decides what counts as speech, and it can be wrong in two
/// opposite directions that feel identical from outside:
///
/// ```
///   too HIGH  →  no utterance ever opens        →  "it never answers"
///   too LOW   →  one opens and never ends       →  "it never answers"
/// ```
///
/// A whole field session was spent on those two. The values that
/// produced them are worth writing down, because they show why no
/// constant could have worked: on one route the phone's noise floor sat
/// at 0.022–0.040 and speech peaked near 0.47; on another, with the
/// neural mouth selected, the SAME phone and the SAME voice measured a
/// floor of 0.002 and a peak of 0.032 — the gain control settles
/// somewhere else when the audio graph changes shape. A gate of 0.060
/// was right in the first case and deaf in the second.
///
/// So the gate is not a property of the device. It is a property of the
/// device **in its current configuration**, and the only honest way to
/// get it is to measure both ends and put it between them.
///
/// Pure and clockless on purpose — the same law the VAD follows. The
/// caller does the listening; this only owns the arithmetic.
public enum GateCalibration {

    public enum Outcome: Sendable, Equatable {
        /// A gate that sits clear of both ends.
        case gate(Float)
        /// Speech was not loud enough against the room to place a gate
        /// between them. Reported rather than papered over: a gate
        /// invented here would be a coin toss wearing a number, and the
        /// person deserves to be told to move somewhere quieter or speak
        /// up instead.
        case tooClose(quiet: Float, speech: Float)
    }

    /// The smallest ratio between speech and silence that can carry a
    /// gate. Below this there is no room to stand between them.
    public static let minimumRatio: Float = 3

    /// - Parameters:
    ///   - quiet: the loudest level measured while nobody spoke.
    ///   - speech: the loudest level measured while somebody did.
    ///
    /// **The midpoint is GEOMETRIC, not arithmetic**, and that is the
    /// one real decision in here. Loudness is a ratio, not a distance:
    /// halfway between 0.002 and 0.032 in a straight line is 0.017,
    /// which sits five times louder than the room but only twice below
    /// speech — lopsided, and it fails first in the direction that goes
    /// silent. The geometric midpoint, 0.008, is four times above the
    /// room and four times below the voice: equally far from both
    /// mistakes, which is what "between" should mean here.
    public static func suggestedGate(quiet: Float, speech: Float) -> Outcome {
        guard quiet >= 0, speech > 0, speech >= quiet * minimumRatio else {
            return .tooClose(quiet: quiet, speech: speech)
        }
        let midpoint = (quiet * speech).squareRoot()
        // Floors and ceilings for the degenerate ends: a silent room
        // reports 0, and the midpoint of anything with 0 is 0 — a gate
        // that opens an utterance on nothing at all.
        let floor = max(quiet * 2, 0.001)
        let ceiling = speech / 2
        return .gate(min(max(midpoint, floor), ceiling))
    }
}
