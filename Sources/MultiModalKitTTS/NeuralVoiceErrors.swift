import TTSKit

// The two errors `NeuralVoice` throws: the device that cannot have the
// variant it was asked for, and the voice that has already been retired.

/// Thrown when the DEVICE cannot have the variant, in this project's words
/// rather than CoreML's (AC-159, D-072). The 1.7B refused on iOS with
/// "Failed to build the model execution plan … error code: -14" — a
/// sentence about a symptom. The cause was documented one dependency away:
/// the compile peak exceeds what iOS provides, so the vendor restricts the
/// variant to macOS, and this error says THAT.
public struct NeuralVoiceUnavailableOnPlatform: Error, CustomStringConvertible {
    public let variant: TTSModelVariant
    public init(variant: TTSModelVariant) { self.variant = variant }
    public var description: String {
        "\(variant.displayName) needs more memory than this device allows "
            + "while compiling — the vendor restricts it to macOS"
    }
}

/// Thrown when a retired voice is asked to speak or to load (D-070).
///
/// Its own type rather than a reused `Retirable.Failure`: a caller catching
/// this is asking "is this voice finished?", which is a different question
/// from "did my load lose a race?", and the two deserve different words.
public struct NeuralVoiceRetired: Error, CustomStringConvertible {
    public init() {}
    public var description: String {
        "this voice was retired — build a new one rather than reviving it"
    }
}
