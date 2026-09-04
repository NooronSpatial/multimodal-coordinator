import AVFAudio
import Foundation
import MLX
import MultiModalKit
import Synchronization

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
/// WHAT THE FIRST REPLY AFTER LAUNCH COSTS, and where (4q, the cold-start
/// measurement §143a has waited for).
///
/// Three costs hide behind "cold", and the first field run mislabelled
/// one of them:
///
/// - **The map** — `loadMilliseconds`. 84–92 ms on Ryad's phone, which
///   is not a read of 164 MB: MLX is lazy, and its own source says arrays
///   "are not fully realized until they are evaluated". This number is
///   the cost of mapping the weights, and the first screen called it
///   "load", which was true and misleading. It keeps the property name
///   for source stability and the screen now calls it what it is.
/// - **The warm-up** — `warmUpMilliseconds`. One short phrase decoded at
///   `ensureModel()` and thrown away (D-085, Ryad's ruling B). This is
///   where the weights are REALLY read and where Metal compiles MLX's
///   kernels — paid at launch, while the person is looking at the
///   screen, instead of inside the first reply. On the phone the first
///   reply's first phrase cost 1343 and 1403 ms before this existed;
///   the second phrase ran at 0.18–0.21×.
/// - **The first reply** — `first`, then `second`. After the warm-up
///   these should be warm from the start; if `first` is still slow, the
///   short warm-up phrase did not compile every kernel a long phrase
///   needs, and that is a finding rather than a rounding error.
///
/// §55 could not separate these: its fp16 run inherited kernels the fp32
/// run had already compiled. This record is the instrument that run
/// lacked, kept on the voice so a screen can show it and a field log can
/// quote it.
public struct KokoroColdStart: Sendable, Equatable {
    public struct Decode: Sendable, Equatable {
        public let wallMilliseconds: Double
        public let audioMilliseconds: Double
        /// The reply's FIRST PHRASE on its own — wall and audio — because
        /// for a one-shot decoder that phrase is where any residual cold
        /// lives, and a reply-level RTF averages it away. This is the
        /// number that says whether D-085's short warm-up compiled every
        /// kernel a long phrase needs.
        public let firstPhrase: Phrase?
        public var realTimeFactor: Double { wallMilliseconds / audioMilliseconds }
    }

    /// One phrase's cost. A sibling of `Decode` rather than a child: the
    /// linter's one-level nesting rule, and the type reads the same.
    public struct Phrase: Sendable, Equatable {
        /// Birth to the first step: decode PLUS the wait for the phrase's
        /// tokens. The number the screen showed as "prefill".
        public let wallMilliseconds: Double
        public let audioMilliseconds: Double
        /// Decoder time alone (D-087 = A). `nil` only from a margin built
        /// without a first decode.
        public let decodeMilliseconds: Double?
        public var realTimeFactor: Double { wallMilliseconds / audioMilliseconds }
        /// The decoder's own rate on this phrase — the number that says
        /// whether the warm-up compiled what a real phrase needs.
        public var decodeRealTimeFactor: Double? { decodeMilliseconds.map { $0 / audioMilliseconds } }
        /// What was spent waiting for text rather than making speech.
        public var waitedForTextMilliseconds: Double? { decodeMilliseconds.map { wallMilliseconds - $0 } }
    }
    /// The lazy MAP of the weights — see above. nil until `ensureModel()`.
    public var loadMilliseconds: Double?
    /// The discarded decode at launch: weights read, kernels compiled.
    public var warmUpMilliseconds: Double?
    /// The first two real replies of the process.
    public var first: Decode?
    public var second: Decode?
    public var decodes = 0

    public init() {}
}

public actor KokoroVoice: SpokenVoice {
    /// HOW LONG A PHRASE MAY GROW, and the arithmetic that moved it.
    ///
    /// The fixtures §55 measured give this mouth's speaking rate:
    /// 40 characters became 2.725 s and 224 became 13.7 s, so ~15
    /// characters per second. With `peak ≈ 336 + 120 × seconds`:
    ///
    /// ```
    ///   60 chars ≈ 4.0 s ≈  816 MB     ← the first default
    ///  120 chars ≈ 8.0 s ≈ 1296 MB     ← this default, the phraser's own
    /// ```
    ///
    /// 60 was chosen against a budget: 884 MB of headroom with the 4B
    /// mind resident, on the default process limit. D-086's entitlement
    /// moved that to **3,580 MB like for like**, and D-087 returned the
    /// cap to the phraser's own 120: a 1.3 GB peak inside 3.5 GB of room
    /// is not a constraint, and every cut the 60 forced was a place
    /// prosody could break. The 60 was never a taste; it was memory, and
    /// the memory is no longer the limit.
    ///
    /// A settable parameter rather than a constant, because that budget
    /// is one phone's with one entitlement, and because a person may
    /// still want to overrule it by ear.
    public static let phraseCharacters = 120

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
    /// Behind a `Mutex` rather than actor-isolated because margins arrive
    /// on the run's own thread, inside a `@Sendable` closure, and hopping
    /// onto the actor from there would mean an unstructured `Task` in a
    /// production path — the house rule says no. The proof: nothing
    /// suspends while it is held, nothing resumes under it.
    private nonisolated let coldStartRecord = Mutex(KokoroColdStart())
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

    /// Why not, when not. `nil` when the weights are in place.
    ///
    /// `ModelBacked` asks only a yes/no, and yes/no is what the demo's
    /// screen showed on this mouth's first field run: "loaded, but the
    /// disk check disagrees". True, and useless.
    public nonisolated func installationProblem() -> String? { weights.missingReport() }

    /// Fetches what is missing, builds the fp16 cast, and LOADS the
    /// decoder. Idempotent: with the assets on disk this is a load, and
    /// with the decoder built it is nothing.
    ///
    /// The load is the parity this method was missing. `NeuralVoice`'s
    /// `ensureModel()` loads its pipeline, which is why the demo's
    /// "preparing" step at launch is worth showing. This one only ensured
    /// files, so the first reply paid the whole model load INLINE on the
    /// coordinator's serial loop — the frozen-conversation fault the 4e
    /// review fixed for Qwen, rebuilt here by omission. Now the load
    /// happens while the person is looking at the screen, and it is
    /// timed, because §143a needs the number.
    public func ensureModel() async throws {
        try await weights.ensure()
        try warmDecoder()
        try await warmKernels()
    }

    /// THE WARM-UP PHRASE, and why it is short (D-085).
    ///
    /// It has to be real words so the G2P and every layer run, and it has
    /// to be SHORT because it runs at launch beside a 2.2 GB mind: the
    /// first in-situ log showed 884 MB of headroom at start, and §55
    /// measured ~120 MB of transient memory per second of audio. A
    /// one-second phrase is a ~120 MB burst; the 2.7-second fixture would
    /// be ~330 MB at the worst possible moment.
    ///
    /// The bet, stated: MLX kernels are specialised per operation and
    /// type, not per sequence length, so a short phrase compiles what a
    /// long one needs. `KokoroColdStart.first` is how that bet is checked
    /// on the phone rather than assumed here.
    static let warmUpPhrase = "Ready to talk."

    /// One decode, discarded, timed. Idempotent: once per process.
    ///
    /// GPU work at launch is exactly the window D-079 guards, and this
    /// mouth's decode is one-shot (AC-181): a retire that lands during it
    /// cannot stop it, only outlive it. The exposure is one short phrase
    /// wide and it is written down here rather than discovered.
    private func warmKernels() async throws {
        guard coldStartRecord.withLock({ $0.warmUpMilliseconds }) == nil,
              let decoder else { return }
        let clock = ContinuousClock()
        let start = clock.now
        try await decoder.decode(Self.warmUpPhrase, temperature: nil) { _ in true }
        let took = start.duration(to: clock.now).milliseconds
        coldStartRecord.withLock { $0.warmUpMilliseconds = took }
    }

    /// What the first reply after launch costs, so far. Readable without
    /// an `await` because a screen reads it and a field log quotes it.
    public nonisolated var coldStart: KokoroColdStart { coldStartRecord.withLock { $0 } }

    /// The first two decodes of the PROCESS, not of the reply: the record
    /// is on the voice, and a retired-and-replaced voice (a phone call,
    /// D-079) starts a fresh one — correct, because its kernels are
    /// already compiled and its load is a new number.
    private nonisolated func recordColdStart(_ margin: DecodeMargin) {
        coldStartRecord.withLock { cold in
            cold.decodes += 1
            let decode = KokoroColdStart.Decode(
                wallMilliseconds: margin.wallMilliseconds,
                audioMilliseconds: margin.audioMilliseconds,
                firstPhrase: margin.firstStepAudioMilliseconds.map {
                    .init(wallMilliseconds: margin.prefillMilliseconds, audioMilliseconds: $0,
                          decodeMilliseconds: margin.firstDecodeMilliseconds)
                })
            if cold.first == nil {
                cold.first = decode
            } else if cold.second == nil {
                cold.second = decode
            }
        }
    }

    private func warmDecoder() throws {
        guard decoder == nil else { return }
        let clock = ContinuousClock()
        let start = clock.now
        _ = try loadedDecoder()
        let took = start.duration(to: clock.now).milliseconds
        coldStartRecord.withLock { $0.loadMilliseconds = took }
    }

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
            // `[weak self]`, and the Mutex reached through it rather than
            // copied out: `Mutex` is non-copyable, so `let record =
            // coldStartRecord` is a consume the compiler refuses — and a
            // strong `self` would close a cycle run → closure → voice →
            // run. Reading a `nonisolated let` on the actor from this
            // `@Sendable` closure needs no hop and no await.
            onMargin: { [weak self] margin in
                self?.recordColdStart(margin)
                listener?(margin)
            })
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
