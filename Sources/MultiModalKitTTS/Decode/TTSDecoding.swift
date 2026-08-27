/// WHAT A DECODER OWES THIS MOUTH — and nothing else (AC-109, D-053 F-6).
///
/// The reason this file exists is a debt, written down rather than
/// implied. The 4e review found a **process abort**: a failed decode
/// reported its terminal, handed the player node back to the engine, and
/// then kept going — popping the next phrase and calling `play()` on a
/// node with no engine, which AVFoundation does not throw on. The fix
/// (`NeuralVoiceRun.retire()`) shipped **green-only**, because
/// `NeuralVoiceRun` held a concrete `TTSKit` and nothing in this repo can
/// make a 1.1 GB CoreML model fail on demand. D-051 accepted that in
/// writing; this seam is it being paid off.
///
/// **It speaks our types, not the vendor's (F-6 = B).** A protocol whose
/// signatures were `GenerationOptions` and `SpeechProgress` would rename
/// the coupling rather than remove it — and a test double would still
/// need `import TTSKit` to fake a decode. Here the whole vendor surface
/// lives in one adapter, `TTSKitDecoder`, and a scripted decoder imports
/// nothing.
///
/// **Internal on purpose.** Its second implementation is a test double,
/// and D-017's rule is that public surface is earned by a second REAL
/// implementation. The day someone wants a different decoder behind this
/// rendering machinery is the day it becomes public — and the day it owes
/// a written contract instead of an internal one.
///
/// **What it deliberately does NOT model.** Voice and language selection
/// (this mouth passes `nil` for both and lets the model resolve its own
/// defaults), the batching mode (a correctness pin about the vendor's own
/// branching — it belongs beside the vendor, and it does), and the
/// returned `SpeechResult` (the samples arrive through `onStep`; the
/// aggregate return was always discarded).
protocol TTSDecoding: Sendable {
    /// The rate the samples handed to `onStep` are sampled at.
    ///
    /// Read from the decoder rather than passed in beside it, and that is
    /// deliberate: the run builds its `AVAudioFormat` from this number, so
    /// a decoder and a format that disagree is precisely the fault the
    /// field reported as a voice "speaking in weird way like someone
    /// drunk" — 24 kHz audio played as if it were 16 kHz. One source of
    /// truth cannot disagree with itself.
    var sampleRate: Int { get }

    /// Decodes `text`, handing back one step's samples at a time.
    ///
    /// - Parameters:
    ///   - text: what to say. The caller has already checked it contains
    ///     something speakable.
    ///   - temperature: sampling temperature, or `nil` for the decoder's
    ///     own default.
    ///   - onStep: called per decode step with that step's samples, which
    ///     may be empty. **Return `false` to stop the decode at its next
    ///     step.** That is an optimisation — it saves compute — and never
    ///     the correctness mechanism: the run's `cancelled` flag is the
    ///     guarantee, and this only spares the machine the work.
    /// - Throws: whatever the decoder failed with. The run turns it into
    ///   one `.failed` update and retires itself.
    func decode(_ text: String,
                temperature: Float?,
                onStep: @escaping @Sendable ([Float]) -> Bool) async throws
}
