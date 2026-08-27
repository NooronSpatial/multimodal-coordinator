import Foundation
import TTSKit

/// The four settings a person can turn, as a value.
///
/// `bakeoff voice-levers` compares them on a Mac and `audio-demo` exposes
/// them on a command line (COMMANDS.md). This is the same four, in a shape a
/// phone can hold, persist and hand to a picker.
public struct VoiceLevers: Sendable, Equatable {
    /// WHICH MODEL SPEAKS. TTSKit ships two — 0.6B and 1.7B — and this
    /// project has only ever measured the small one. The big one is
    /// roughly three times the parameters, so it is a genuine question
    /// with a genuine risk: this phone already decodes at 1.06× real time
    /// with the cushion barely covering a long reply (§48), and a slower
    /// decoder makes that worse before it makes anything better.
    ///
    /// A lever rather than a new default, for exactly that reason: it can
    /// be compared by ear and by the RTF line on the same device, in the
    /// same session, which is the only way this project has ever settled a
    /// voice question.
    public var model: TTSModelVariant
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

    public init(model: TTSModelVariant = .qwen3TTS_0_6b,
                decoder: Qwen3MultiCodeDecoderMode = .fused,
                vocoder: Qwen3SpeechDecoderMode = .latencyOptimized,
                temperature: Float? = nil,
                lead: Duration? = nil) {
        self.model = model
        self.decoder = decoder
        self.vocoder = vocoder
        self.temperature = temperature
        self.lead = lead
    }

    /// What the phone can actually run, and what it should run.
    ///
    /// `.fused` does not load on iOS 18+, so a phone that starts there
    /// starts broken — that half was never in doubt.
    ///
    /// `throughputOptimized` is Ryad's ruling (D-071), and it reverses the
    /// Mac. §31 ranked throughput 3rd and 4th of six; §36 measured it
    /// winning BOTH columns on his iPhone — ~2.4 s adapted first audio
    /// against ~3.1 s, ~9.4 s total against ~10.7 s — because a faster
    /// decode needs a smaller cushion, and the phone is the machine the
    /// cushion exists for. §42 then found the two TIE by ear, which is what
    /// hands the ranking to the numbers.
    ///
    /// The Mac's default is untouched: `audio-demo` still starts `.fused` +
    /// latency, because a Mac has throughput to spare and never needed the
    /// trade.
    public static let phoneDefault = VoiceLevers(decoder: .stepped,
                                                 vocoder: .throughputOptimized)

    public func makeVoice() -> NeuralVoice {
        NeuralVoice(variant: model,
                    lead: lead,
                    multiCodeDecoderMode: decoder,
                    speechDecoderMode: vocoder,
                    temperature: temperature)
    }

    // MARK: - the one parser (D-072 F-3 = A, AC-162)

    /// A lever flag whose value this project cannot honor — said in our
    /// words, with the allowed tokens beside the wrong one. The fifth
    /// hand-rolled ternary was rejected (D-072) partly because it turned
    /// `--decoder=banana` into `.fused` without complaint.
    public struct FlagError: Error, Equatable {
        public let flag: String
        public let given: String
        public let allowed: String
        public var message: String {
            "--\(flag)=\(given) — this project knows \(allowed)"
        }
    }

    /// The five lever flags, parsed the same way for every caller.
    ///
    /// Lives in the library because parsing that lives in an executable is
    /// structurally untestable (no test target can import one) — which is
    /// how the model lever shipped in `75e1381` reached the phone's Bench
    /// and never reached the terminal (D-072 F-3).
    ///
    ///   --voice-model=0.6b|1.7b   WHICH MODEL SPEAKS — the exact tokens
    ///                             the iOS app persists, so the terminal
    ///                             and the phone say the same words (F-1)
    ///   --decoder=fused|stepped
    ///   --speech=latency|throughput
    ///   --temperature=<float>     omit for the model default
    ///   --lead=<ms>               omit to DERIVE from the decoder
    ///
    /// An absent flag keeps `base`'s value; a present flag with a value
    /// this project cannot honor throws — never a silent fallback.
    public static func parsed(fromArguments arguments: [String],
                              base: VoiceLevers = VoiceLevers()) throws -> VoiceLevers {
        func flag(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }
                .map { String($0.dropFirst(name.count + 3)) }
        }
        var levers = base
        if let token = flag("voice-model") {
            switch token {
            case "0.6b": levers.model = .qwen3TTS_0_6b
            case "1.7b": levers.model = .qwen3TTS_1_7b
            default: throw FlagError(flag: "voice-model", given: token,
                                     allowed: "0.6b|1.7b")
            }
        }
        if let token = flag("decoder") {
            switch token {
            case "fused": levers.decoder = .fused
            case "stepped": levers.decoder = .stepped
            default: throw FlagError(flag: "decoder", given: token,
                                     allowed: "fused|stepped")
            }
        }
        if let token = flag("speech") {
            switch token {
            case "latency": levers.vocoder = .latencyOptimized
            case "throughput": levers.vocoder = .throughputOptimized
            default: throw FlagError(flag: "speech", given: token,
                                     allowed: "latency|throughput")
            }
        }
        if let token = flag("temperature") {
            guard let value = Float(token) else {
                throw FlagError(flag: "temperature", given: token,
                                allowed: "a number, e.g. 0.7")
            }
            levers.temperature = value
        }
        if let token = flag("lead") {
            guard let ms = Int(token.replacingOccurrences(of: "ms", with: "")) else {
                throw FlagError(flag: "lead", given: token,
                                allowed: "milliseconds, e.g. 400ms")
            }
            levers.lead = .milliseconds(ms)
        }
        return levers
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
        let modelName = variant == .qwen3TTS_1_7b ? "1.7B" : "0.6B"
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
        // ONE snapshot, compared against itself. This re-read `currentLead`,
        // and the decode side writes the learned value from another thread —
        // so the number and its label could come from different instants and
        // the line could say "measured here" beside the constant's value.
        let source = lead == cushion ? "" : " · measured here"
        return "\(modelName) · \(decoderName) · \(vocoderName) · temp \(temperatureName)"
            + " · lead \(cushionName)\(source)"
    }
}
