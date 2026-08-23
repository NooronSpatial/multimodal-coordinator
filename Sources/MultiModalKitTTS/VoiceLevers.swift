import Foundation
import TTSKit

/// The four settings a person can turn, as a value.
///
/// `bakeoff voice-levers` compares them on a Mac and `audio-demo` exposes
/// them on a command line (COMMANDS.md). This is the same four, in a shape a
/// phone can hold, persist and hand to a picker.
public struct VoiceLevers: Sendable, Equatable {
    public var decoder: Qwen3MultiCodeDecoderMode
    public var vocoder: Qwen3SpeechDecoderMode
    /// `nil` is the model's own — NOT zero. Temperature 0 had the fastest
    /// first audio of all six configurations and the worst sound
    /// (INSTRUMENTS §32).
    public var temperature: Float?
    /// `nil` leaves the cushion to be derived: this machine's measurement if
    /// it has one, the decoder's constant until then (D-068). A number here
    /// is a human overriding both, which D-068 D says is allowed and wins.
    public var lead: Duration?

    public init(decoder: Qwen3MultiCodeDecoderMode = .fused,
                vocoder: Qwen3SpeechDecoderMode = .latencyOptimized,
                temperature: Float? = nil,
                lead: Duration? = nil) {
        self.decoder = decoder
        self.vocoder = vocoder
        self.temperature = temperature
        self.lead = lead
    }

    /// What the phone can actually run. `.fused` does not load on iOS 18+,
    /// so a phone that starts there starts broken.
    public static let phoneDefault = VoiceLevers(decoder: .stepped)

    public func makeVoice() -> NeuralVoice {
        NeuralVoice(lead: lead,
                    multiCodeDecoderMode: decoder,
                    speechDecoderMode: vocoder,
                    temperature: temperature)
    }
}

extension NeuralVoice {
    /// What is ACTUALLY in force, read off this voice.
    ///
    /// ## The signature is the guarantee (AC-143)
    ///
    /// This is a property of a **voice**, not a function of a `VoiceLevers`.
    /// A screen that shows it is therefore reporting the object that will do
    /// the speaking, and cannot be showing what a picker merely selected.
    /// The two differ every time an apply fails, is still in flight, or
    /// silently falls back — which is exactly when a person is looking at
    /// the screen to find out what happened.
    ///
    /// It is the same discipline as `chosenMouth`'s stderr banner on the
    /// Mac, and it exists for the same reason: the slow voice was a silent
    /// disagreement between the decoder in use and a cushion sized for a
    /// different one, and nothing on screen said so.
    public nonisolated var inForce: String {
        let decoderName = multiCodeDecoderMode == .fused ? "fused" : "stepped"
        let vocoderName = speechDecoderMode == .throughputOptimized
            ? "throughput" : "latency"
        let temperatureName = temperature.map { "\($0)" } ?? "model default"
        let cushion = currentLead
        let cushionName: String
        if cushion == .zero {
            cushionName = "none needed"
        } else {
            let ms = cushion.components.seconds * 1000
                + cushion.components.attoseconds / 1_000_000_000_000_000
            cushionName = "\(ms) ms"
        }
        // Named so the reader can tell a measured cushion from a typed one:
        // the first is this machine's, the second is a person overruling it.
        let source = lead == currentLead ? "" : " · measured here"
        return "\(decoderName) · \(vocoderName) · temp \(temperatureName)"
            + " · lead \(cushionName)\(source)"
    }
}
