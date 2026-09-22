/// An organ whose work needs weights on disk (D-078).
///
/// ## The gap this closes
///
/// Every organ in this pipeline that runs a real model — both ears, the
/// mind, and the neural mouth — answered the same two questions with the
/// same two method names, and NONE of them was in a protocol. Four types,
/// one shape, no contract. So a caller that held `any TranscriptionEngine`
/// could not ask either question, and the terminal demo reached for the
/// only tool left:
///
/// ```swift
/// case "apple": await (engine as! AppleSpeechEngine).modelInstalled()
/// default:      await (engine as! WhisperEngine).modelInstalled()
/// ```
///
/// A force cast decided by a STRING, against an object built somewhere
/// else. If those two ever disagree the app does not misbehave — it
/// crashes. SwiftLint found the cast; the cast was the symptom.
///
/// ## The doctrine this protocol states (and does not invent)
///
/// It is the rule `WhisperEngine` already followed and wrote down:
///
/// - **Asking is free and never downloads.** `modelInstalled()` reads the
///   disk and nothing else. A method that quietly fetched 142 MB because
///   someone asked a question would be a trap.
/// - **Fetching is explicit and idempotent.** `ensureModel()` is the only
///   thing that may reach the network, a person's action stands behind it,
///   and calling it twice costs nothing the second time.
/// - **"Installed" means offline-capable.** True here promises the organ
///   can work with the network unplugged.
///
/// ## Why it returns nothing (fork B1, D-078)
///
/// Three of the four already return `Void`; `LocalMind.ensureModel()`
/// hands back its loaded `ModelContainer` so a caller can use the model.
/// That is a DIFFERENT job — "make sure the weights are there" versus
/// "give me the loaded thing" — and folding it in would need an
/// `associatedtype`, which makes `any ModelBacked` nearly unusable for the
/// caller this protocol exists to serve. So the value-returning method
/// stays `LocalMind`'s own, and the conformance is a thin call to it.
/// ## What 5a added, and why it is here rather than beside it (D-114
/// F-6 = A)
///
/// The requirement that opened 5a asked for three things on "every
/// model-backed engine": a percentage while a model downloads, a size
/// before the tap, and a delete. They are on THIS protocol because the
/// caller that needs them holds `any ModelBacked` — a Models page with a
/// row per engine — and a second protocol for three of five engines
/// would make that page ask "which kind are you" before it could draw a
/// bar.
///
/// **No default implementations.** A `deleteModel()` that did nothing,
/// or an `ensureModel(progress:)` that reported `1.0` when it returned,
/// would let a conformer look finished while doing nothing — the fake
/// instrument this project refuses. Every conformer writes all five.
public protocol ModelBacked: Sendable {
    /// Is the model on disk right now? Never downloads, never throws:
    /// a question is not an instruction.
    func modelInstalled() async -> Bool

    /// Put the model on disk if it is not there. Explicit, idempotent, and
    /// the only member here that may touch the network.
    func ensureModel() async throws

    /// The same, reporting how far along it is: `0…1`, never decreasing
    /// within one call, and `1.0` exactly once, last — including for a
    /// model that was already installed, which says `1.0` and asks the
    /// network nothing (5a, AC-291).
    ///
    /// Four of the five engines report BYTES written over bytes expected,
    /// through `ModelDownloader`; the Apple engine forwards the system's
    /// own fraction, because the system owns its bytes.
    func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws

    /// What `ensureModel` would download, in bytes, WITHOUT touching the
    /// network — for a screen that must show a size before a person taps
    /// (5a, AC-294).
    ///
    /// `nil` means "not known here", and it is never a guess: the engines
    /// whose repositories this library chose answer with a measured
    /// number; the mind, whose repository the APP chooses, answers from
    /// the listing this device made and `nil` before it has made one; the
    /// Apple engine answers `nil` always, because the system owns the
    /// bytes. `LocalMindModel.expectedInstall()` is the exact question,
    /// and it costs one request.
    func expectedDownloadBytes() -> Int64?

    /// Retire what is resident, stop a transfer in flight, and remove
    /// exactly what this engine's `ensureModel` wrote — nothing shared,
    /// nothing another variant needs, nothing the app put there itself
    /// (5a, AC-295). `modelInstalled()` reads `false` afterwards on every
    /// engine that owns its files.
    ///
    /// - Throws: when something named could not be removed, so a screen
    ///   can say why `modelInstalled()` still reads `true`.
    func deleteModel() async throws
}
