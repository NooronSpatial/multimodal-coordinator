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
public protocol ModelBacked: Sendable {
    /// Is the model on disk right now? Never downloads, never throws:
    /// a question is not an instruction.
    func modelInstalled() async -> Bool

    /// Put the model on disk if it is not there. Explicit, idempotent, and
    /// the only member here that may touch the network.
    func ensureModel() async throws
}
