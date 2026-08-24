/// One point in the tuning space, named the way INSTRUMENTS names it.
///
/// Deliberately free of TTSKit's types. This module knows nothing about
/// CoreML, decoders or voices — it knows about *rows*, and the app maps
/// these names onto whatever it is driving. That is what keeps the module
/// testable on a machine with no models installed.
public struct BenchConfiguration: Sendable, Equatable, Hashable {
    public enum Decoder: String, Sendable, CaseIterable {
        case fused, stepped
    }
    public enum Vocoder: String, Sendable, CaseIterable {
        case latency, throughput
    }

    public let name: String
    public let decoder: Decoder
    public let vocoder: Vocoder
    /// `nil` means "the model's own", which is NOT the same as zero —
    /// temperature 0 was the fastest to first audio of all six and the
    /// worst to listen to (INSTRUMENTS §32).
    public let temperature: Float?

    public init(name: String, decoder: Decoder, vocoder: Vocoder,
                temperature: Float? = nil) {
        self.name = name
        self.decoder = decoder
        self.vocoder = vocoder
        self.temperature = temperature
    }

    /// THE FOUR THE PHONE CAN COMPARE.
    ///
    /// `.fused` is absent from this list and present in the picker, which
    /// is not a contradiction: D-066 F-2 keeps it selectable so it can
    /// refuse with the real CoreML error, but a sweep that includes a
    /// configuration known not to load would spend a third of its runtime
    /// measuring a failure it already understands.
    public static let phone: [BenchConfiguration] = [
        .init(name: "stepped + latency", decoder: .stepped, vocoder: .latency),
        .init(name: "stepped + throughput", decoder: .stepped, vocoder: .throughput),
        .init(name: "stepped + temp 0", decoder: .stepped, vocoder: .latency,
              temperature: 0),
        .init(name: "stepped + throughput + temp 0", decoder: .stepped,
              vocoder: .throughput, temperature: 0),
    ]

    /// The six `bakeoff voice-levers` compares, so a phone table and a Mac
    /// table can be read side by side (INSTRUMENTS §31, §32).
    public static let mac: [BenchConfiguration] = [
        .init(name: "stepped + latency", decoder: .stepped, vocoder: .latency),
        .init(name: "fused", decoder: .fused, vocoder: .latency),
        .init(name: "stepped + throughput", decoder: .stepped, vocoder: .throughput),
        .init(name: "fused + throughput", decoder: .fused, vocoder: .throughput),
        .init(name: "stepped + temp 0", decoder: .stepped, vocoder: .latency,
              temperature: 0),
        .init(name: "fused + temp 0", decoder: .fused, vocoder: .latency,
              temperature: 0),
    ]
}
