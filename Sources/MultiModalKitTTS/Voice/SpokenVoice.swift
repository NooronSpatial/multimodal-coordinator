import MultiModalKit

/// A NEURAL MOUTH THIS APP CAN HOLD WITHOUT NAMING ITS VENDOR
/// (4q, Ryad's ruling A; D-078's lesson, met a second time).
///
/// ## The hole this closes, which the repo has seen before
///
/// D-078 found four organs answering the same two questions with the same
/// two method names and none of them in a protocol, so a caller holding
/// `any TranscriptionEngine` reached for a force cast decided by a string.
/// The mouths were about to repeat it exactly: `TranscribeModel` stored a
/// concrete `NeuralVoice` and called five things on it, so a second mouth
/// could be *built* and never *chosen*.
///
/// `SpeechSynthesizing` says how to speak and `ModelBacked` says how to
/// get weights. What was missing is everything in between — where a voice
/// renders, how it is stopped, how it is released, what it reports, and
/// what it says it is.
///
/// ## Why `inForce` belongs here and is better for moving
///
/// It used to be an extension on `NeuralVoice` listing Qwen's levers:
/// model, decoder, vocoder, temperature, cushion. Those words mean
/// nothing to Kokoro, which has none of them. As a protocol requirement
/// each voice describes ITSELF, which is what AC-143 wanted in the first
/// place: a screen showing this is reporting **the object that will do
/// the speaking**, not what a picker selected.
public protocol SpokenVoice: SpeechSynthesizing, ModelBacked {
    /// Renders replies on `host` from now on.
    ///
    /// Settable rather than fixed at init because the two lifetimes do not
    /// match: a capture session starts and stops every time someone taps
    /// Listen, while a loaded model should be kept. Rebuilding a voice to
    /// change where it speaks pays for the weights again on every tap.
    func render(on host: any PlaybackHost) async

    /// Stops anything THIS VOICE started, and nothing it was handed
    /// (D-052's ownership rule). Safe twice, and safe on a voice that
    /// never spoke.
    func shutdown() async

    /// Releases the weights and takes any reply in progress with it.
    ///
    /// **Terminal**: a retired voice never loads again (D-070). Two field
    /// faults live behind this one method — a reply that kept a whole
    /// pipeline alive through its drain task while the app thought it had
    /// freed it, and iOS killing the app for GPU work after backgrounding
    /// (D-079). Any mouth this app can choose must be able to let go.
    func retire() async

    /// Installs an observer for decode margins — how fast this voice
    /// decodes against the audio it produces.
    ///
    /// Always meaningful, never only for the slow mouth: a margin from a
    /// fast decoder is what will eventually let D-084's cushion apparatus
    /// be removed with evidence instead of optimism.
    func reportMargins(to handler: @escaping @Sendable (DecodeMargin) -> Void) async

    /// What is ACTUALLY in force, read off this voice — its own words,
    /// its own levers.
    nonisolated var inForce: String { get }
}
