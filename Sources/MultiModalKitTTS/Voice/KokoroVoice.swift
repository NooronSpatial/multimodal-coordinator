import AVFAudio
import Foundation
import MLX
import MultiModalKit

/// The second mouth (4q, D-084): Kokoro-82M, decoded by `KokoroDecoder`
/// and rendered by the SAME `NeuralVoiceRun` the first mouth uses.
///
/// **What is reused is the point of this type.** The run, the phraser, the
/// lead, the barge-in ticket, the liveness funnel, the margin reporting —
/// none of it is rewritten. `NeuralVoiceRun` takes `any TTSDecoding`, so
/// swapping the vendor swaps one object. Everything this project learned
/// the hard way about speaking (D-045's audible rule, D-051's retire,
/// D-055's funnel, D-070's terminal) applies to Kokoro on day one because
/// it was never in the decoder to begin with.
///
/// ## Why Kokoro is the default now
///
/// INSTRUMENTS §55, on Ryad's phone, both mouths in one process under one
/// stopwatch: **RTF 0.20 against 1.35**. Qwen3 decodes slower than it
/// speaks, which is the reason every cushion in this library exists. A
/// decoder at 0.20 does not make that apparatus smaller — it removes its
/// reason to exist. D-084 rules the swap; this type is the swap.
///
/// ## What it costs, and what this type does about it
///
/// Kokoro is one-shot. It returns a whole phrase at once, so its
/// transient memory scales with PHRASE LENGTH — §55 measured
/// `peak ≈ 336 MB + 120 MB × seconds of audio` at fp16. Left uncapped
/// that is an unbounded allocation on a phone that already carries a
/// 2.2 GB mind.
///
/// So this voice cuts phrases shorter than the first mouth does, and the
/// number is derived rather than chosen — see `phraseCharacters`.
public actor KokoroVoice: SpokenVoice {
    /// HOW SHORT A PHRASE MUST BE KEPT, and the arithmetic behind it.
    ///
    /// The fixtures §55 measured give this mouth's speaking rate:
    /// 40 characters became 2.725 s and 224 became 13.7 s, so ~15
    /// characters per second. With `peak ≈ 336 + 120 × seconds`:
    ///
    /// ```
    ///   60 chars ≈ 4.0 s ≈  816 MB     ← this default
    ///  120 chars ≈ 8.0 s ≈ 1296 MB     ← the phraser's own default
    /// ```
    ///
    /// 60 is chosen against a stated budget: the phone measured ~3.3 GB
    /// of total footprint before jetsam, the local mind holds ~2.2 GB of
    /// it, and what is left has to cover Whisper, the app and this mouth.
    ///
    /// **The cost is real and is not hidden:** a shorter cap cuts more
    /// often, and every cut is a place prosody can break. It is cheap in
    /// TIME — at RTF 0.20 a 4-second phrase decodes in 0.8 s, and the run
    /// schedules phrases back to back — so the trade is memory against
    /// how the voice reads, not memory against speed.
    ///
    /// A settable parameter rather than a constant, because the budget
    /// above is one phone's, and because 60-versus-120 is a judgement a
    /// person should be able to overrule by ear.
    public static let phraseCharacters = 60

    /// `nonisolated` because they are immutable and `Sendable`, and
    /// because `inForce` must be readable from a screen without an
    /// `await` — AC-143's whole point is that the line a person reads
    /// describes the object that will speak.
    private nonisolated let weights: KokoroWeights
    private nonisolated let lead: Duration
    private nonisolated let phraseCharacters: Int

    private var decoder: KokoroDecoder?
    private var providedHost: (any PlaybackHost)?
    private var ownHost: AudioEnginePlaybackHost?
    private var speaking: NeuralVoiceRun?
    private var marginHandler: (@Sendable (DecodeMargin) -> Void)?
    /// A retired voice never loads again — that is what retiring MEANS
    /// (D-070). One latch, checked at the one door that builds anything.
    private var isRetired = false

    /// - Parameters:
    ///   - weights: where the model lives and at which precision. fp16 is
    ///     that type's default because §55 measured it ~180 MB cheaper at
    ///     identical speed, and Ryad heard no difference.
    ///   - lead: the cushion. **Deliberately not derived and not
    ///     adaptive.** `AdaptiveLead` exists because Qwen3 decodes slower
    ///     than it speaks; a decoder at RTF 0.20 has nothing to learn
    ///     from. D-084 forbids deleting that apparatus until Kokoro's RTF
    ///     is confirmed below 1.0 INSIDE this pipeline, so it stays where
    ///     it is and this mouth simply does not use it yet.
    ///   - phraseCharacters: the memory bound described above.
    public init(weights: KokoroWeights,
                lead: Duration = .zero,
                phraseCharacters: Int = KokoroVoice.phraseCharacters) {
        self.weights = weights
        self.lead = lead
        self.phraseCharacters = phraseCharacters
    }

    // MARK: - ModelBacked (D-078)

    /// Reads the disk and nothing else — asking is free and never
    /// downloads. True here promises this mouth can speak with the
    /// network unplugged, at the precision it was configured for.
    public func modelInstalled() async -> Bool { weights.isInstalled() }

    /// Fetches what is missing and builds the fp16 cast. Idempotent: with
    /// the assets on disk this is a cast check, not a fetch.
    public func ensureModel() async throws { try await weights.ensure() }

    /// The same fetch with a progress fraction, for a screen that would
    /// otherwise show nothing for 327 MB. `ensureModel()` stays the
    /// protocol's shape; this is the app's door.
    public func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await weights.ensure(progress: progress)
    }

    // MARK: - speaking

    /// Renders replies on `host` from now on. Settable rather than fixed
    /// at init for `NeuralVoice`'s reason: a capture session starts and
    /// stops on every tap, while a loaded model should be kept.
    public func render(on host: any PlaybackHost) { providedHost = host }

    /// Stops anything THIS VOICE started (D-052's ownership rule): a host
    /// handed in belongs to the caller, a host built here is ours to stop.
    /// Safe twice, and safe on a voice that never spoke.
    public func shutdown() {
        ownHost?.stopRendering()
        ownHost = nil
    }

    /// Installs the margin observer. Always installed on the run, even
    /// when nobody registered a handler — margins used to be computed
    /// only if someone was watching, and a voice that measures itself
    /// only when observed is not measuring itself.
    public func reportMargins(to handler: @escaping @Sendable (DecodeMargin) -> Void) {
        marginHandler = handler
    }

    /// Releases the weights and takes any reply in progress with it.
    ///
    /// The order is D-070's and D-079's, both paid for in the field: latch
    /// FIRST, in this actor step and before any await, so a caller
    /// arriving during a suspension already finds a voice that says no.
    /// Then cancel the reply — without that the run keeps itself alive
    /// through its drain task and holds the weights, so retiring frees
    /// nothing exactly while the assistant is speaking, which is when a
    /// lever gets changed. Then drop the decoder, and let MLX return what
    /// it was holding.
    public func retire() async {
        isRetired = true
        shutdown()
        let dying = speaking
        speaking = nil
        await dying?.cancel()
        decoder = nil
        MLX.Memory.clearCache()
    }

    public func openUtterance() async throws -> any SynthesisRun {
        let decoder = try loadedDecoder()
        let host: any PlaybackHost
        if let providedHost {
            host = providedHost
        } else if let ownHost {
            host = ownHost
        } else {
            let fresh = AudioEnginePlaybackHost()
            ownHost = fresh
            host = fresh
        }
        let listener = marginHandler
        let run = try NeuralVoiceRun(
            decoder: decoder, host: host,
            lead: PlaybackLead(target: lead),
            phrasing: SpeechPhraser.Config(maxPhraseCharacters: phraseCharacters),
            onMargin: { margin in listener?(margin) })
        speaking = run
        return run
    }

    /// Built once and kept. The weights are ~164 MB at fp16 and the load
    /// is seconds; rebuilding per utterance would pay for it on every
    /// reply.
    private func loadedDecoder() throws -> KokoroDecoder {
        guard !isRetired else { throw KokoroVoiceRetired() }
        if let decoder { return decoder }
        let fresh = try KokoroDecoder(weights: weights)
        decoder = fresh
        return fresh
    }
}

public struct KokoroVoiceRetired: Error, CustomStringConvertible {
    public var description: String {
        "this Kokoro voice was retired; retiring is terminal (D-070)"
    }
}

extension KokoroVoice {
    /// What is ACTUALLY in force, read off this voice (AC-143, now a
    /// `SpokenVoice` requirement).
    ///
    /// Kokoro's levers are not Qwen's, and this line is the proof that
    /// making `inForce` a protocol requirement was the right shape: it
    /// names precision and the phrase cap, because those are what this
    /// mouth actually has. A shared implementation would have printed
    /// "0.6B · fused · latency" about a model with none of those things.
    public nonisolated var inForce: String {
        "Kokoro-82M · \(weights.precision.rawValue) · phrases ≤ \(phraseCharacters) chars"
    }
}
