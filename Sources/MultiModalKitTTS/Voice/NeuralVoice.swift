import AVFAudio
import Foundation
import MultiModalKit
import TTSKit

/// The second mouth (SPEC §61, D-045): Qwen3 neural TTS behind the same
/// `SpeechSynthesizing` seam Apple's voice already implements.
///
/// The milestone's reason to exist: every seam in this library has two
/// real implementations except this one, so "we can switch mouths" was a
/// CLAIM where the input side had a PROOF. The proof is a bake-off.
///
/// **What this type does NOT do, by ruling (D-045 F-1 = B):** it never
/// asks TTSKit to play anything. It takes the PCM from `generate` and
/// renders it through the pipeline's own engine, because D-043 measured
/// that iOS voice processing cancels only what its own audio unit
/// renders — so a reply we render ourselves is the first one the
/// canceller can see. The cost, accepted knowingly: pre-buffering and
/// resampling become ours to get right.
///
/// This file's first job is the part that can be tested without a
/// speaker: knowing whether the model is here, and saying so honestly.
/// An actor for the same reason `WhisperEngine` is one: it caches a
/// loaded CoreML pipeline, and that is mutable state which must not be
/// touched from two places at once.
public actor NeuralVoice: SpeechSynthesizing, ModelBacked {
    /// Which Qwen3 variant to speak with. 0.6B is the smaller, faster
    /// one; the bake-off's numbers decide whether the larger earns its
    /// download.
    /// `nonisolated` because it never changes and callers ask it while
    /// printing — an actor hop to read a `let` is ceremony.
    public nonisolated let variant: TTSModelVariant

    /// The loaded pipeline, kept so a second utterance does not pay the
    /// load again.
    /// TERMINAL, and it never goes back (D-070). A retired voice must not
    /// build a second pipeline: that is the 2.2 GB where 1.1 was intended,
    /// the jetsam kill of INSTRUMENTS §28/§29 that retiring exists to
    /// prevent. AC-145 claimed this and proved only that `retire()` was
    /// CALLED; the review proved the voice would happily reload afterwards.
    public private(set) var isRetired = false

    /// How many times this voice has actually REACHED for the models.
    ///
    /// Not decoration, and not a metric: it is the only way a test can tell
    /// "refused" from "refused after loading 1.1 GB", and those are
    /// different outcomes with the same visible result. A review found the
    /// first version of the terminal test passing with the guard removed —
    /// it threw either way, ninety-six seconds later. Counting the reach is
    /// what makes "it does not rebuild" a testable sentence.
    private(set) var loadAttempts = 0

    /// The reply in flight, held WEAKLY.
    ///
    /// A speaking `NeuralVoiceRun` keeps itself alive — `beginDraining`
    /// stores `Task { [self] … }` — and it holds the `TTSKit` strongly
    /// through its decoder. So dropping this voice's own reference frees
    /// nothing while a reply is speaking, and `retire()` has to reach IN and
    /// cancel. Weak so that this handle never extends the run's life by
    /// itself; the run's own drain task is what keeps it alive, and the run
    /// is what must be told to stop.
    private weak var speaking: NeuralVoiceRun?

    /// The loaded models, behind the shape that gets this right (D-051).
    /// Hand-written four times here and wrong four times; `Retirable` holds
    /// the FIFO, the reentrancy re-check and the generation ticket that
    /// stops a retired pipeline being resurrected by its own in-flight load.
    private let held = Retirable<TTSKit>()

    /// WHERE THIS VOICE RENDERS (AC-108, D-048). Handing in a host is
    /// how a caller makes the reply CANCELLABLE: D-043 measured that iOS
    /// voice processing removes only what its own audio unit renders, so
    /// a reply rendered on the host that also CAPTURES is the first one
    /// the canceller can see. `nil` means "make your own", which works
    /// everywhere and cancels nowhere.
    ///
    /// This used to read "sharing the capture engine is not yet possible
    /// — `MicrophoneSource` keeps its own private — and that is exactly
    /// the work milestone 4f carries." D-048 pulled that work forward
    /// the moment AC-104 turned out to be untestable without it. The old
    /// sentence is quoted rather than deleted because the decision log
    /// refers to it.
    private var providedHost: (any PlaybackHost)?
    private var ownHost: AudioEnginePlaybackHost?

    /// How much audio to bank before the first sound (D-046 = A,
    /// AC-107). AC-102 measured this voice decoding SLOWER than it
    /// plays, so a renderer that starts on the first buffer gaps from
    /// the first buffer. The sizing rule lives with the rule it sizes:
    /// `PlaybackLead.deficit(forReplyOf:realTimeFactor:)`.
    ///
    /// Injected rather than fixed, because the right value is a property
    /// of the MACHINE — a phone will need more of it than a Mac — and
    /// because `.zero` reproduces AC-102's measured behaviour exactly,
    /// which is how the before/after number stays honest.
    public nonisolated let lead: Duration

    /// What the caller ASKED for, or nil if they left it to be derived.
    /// Kept separately from `lead` because the two answer different
    /// questions: `lead` is what this voice started with, `explicitLead` is
    /// whether a human overrode anything — and D-068 D says a human's number
    /// outranks a measured one.
    private nonisolated let explicitLead: Duration?

    /// D-068 A. Learns this machine's cushion from the margin every reply
    /// reports, because the constant is a Mac's (INSTRUMENTS §33).
    nonisolated let adaptive = AdaptiveLead()

    /// The cushion the NEXT reply will use, and the whole precedence rule
    /// in one line:
    ///
    ///     a human's number  →  this machine's measurement  →  the constant
    ///
    /// `lead` is what this voice was born with; this is what it has learned
    /// since. They differ only after a reply has been decoded on a machine
    /// whose factor is not the one baked in.
    public nonisolated var currentLead: Duration {
        explicitLead
            ?? adaptive.target
            ?? NeuralVoice.defaultLead(for: multiCodeDecoderMode)
    }

    /// How the multi-code decoder runs each 15-code frame. **Defaults to
    /// `.fused` (D-047)**, which is NOT TTSKit's own default.
    ///
    /// `.stepped` costs ~35 CoreML predictions per 80 ms frame; `.fused`
    /// does the whole frame in one prediction with in-graph sampling,
    /// leaving about 5. AC-106 measured 1.066 → 0.752, and AC-103 found
    /// no quality difference by ear or by round-trip WER. Dispatch
    /// overhead, not matrix maths, was where the time went.
    public nonisolated let multiCodeDecoderMode: Qwen3MultiCodeDecoderMode
    /// How the vocoder runs. `.throughputOptimized` produces four audio
    /// frames per call instead of one.
    public nonisolated let speechDecoderMode: Qwen3SpeechDecoderMode
    /// Sampling temperature, or `nil` for TTSKit's default. Zero is
    /// greedy — every head takes the argmax branch, which removes about
    /// half the host round-trips per frame.
    public nonisolated let temperature: Float?
    /// Fixes the sampler. INSTRUMENTS §11 recorded this voice producing
    /// 8240 ms of audio for a sentence one run and 6480 ms the next;
    /// a seed is what makes a bake-off reproducible rather than one draw.
    public nonisolated let seed: UInt64?

    /// Whether this DEVICE can have this variant — injectable, and the
    /// injection is the testability (AC-159). The vendor's verdict is
    /// `TTSModelVariant.isAvailableOnCurrentPlatform`, which is `false` for
    /// 1.7B on iOS ("more peak memory during CoreML compilation than
    /// iOS/iPadOS devices can reliably provide"). But CI runs on macOS,
    /// where that property is ALWAYS true — a guard wired straight to it
    /// could never be watched firing on the only machine that tests it.
    /// `nil` means "ask the vendor", which is what every real caller does.
    nonisolated let platformVerdict: Bool?

    public init(variant: TTSModelVariant = .qwen3TTS_0_6b,
                renderingOn host: (any PlaybackHost)? = nil,
                lead: Duration? = nil,
                multiCodeDecoderMode: Qwen3MultiCodeDecoderMode = .fused,
                speechDecoderMode: Qwen3SpeechDecoderMode = .latencyOptimized,
                temperature: Float? = nil,
                seed: UInt64? = nil,
                availableOnThisPlatform: Bool? = nil) {
        self.variant = variant
        self.platformVerdict = availableOnThisPlatform
        self.providedHost = host
        // nil means "derive it from the decoder I was actually given",
        // which is the only way the two cannot disagree.
        self.lead = lead ?? NeuralVoice.defaultLead(for: multiCodeDecoderMode)
        self.explicitLead = lead
        self.multiCodeDecoderMode = multiCodeDecoderMode
        self.speechDecoderMode = speechDecoderMode
        self.temperature = temperature
        self.seed = seed
    }

    /// Called with the decode margin at the end of every reply, if set.
    private var marginHandler: (@Sendable (DecodeMargin) -> Void)?

    /// Reports what each reply cost to decode.
    ///
    /// A separate call rather than an init parameter for the same reason
    /// `render(on:)` is: the voice is built once and lives for the app's
    /// lifetime, while whoever wants to watch it comes and goes.
    public func reportMargins(to handler: @escaping @Sendable (DecodeMargin) -> Void) {
        marginHandler = handler
    }

    /// Stops anything THIS VOICE started (D-052).
    ///
    /// The rule is ownership: a host handed in by a caller belongs to
    /// that caller and is never touched here; a host this voice built for
    /// itself is this voice's to stop. Without it, a caller who simply
    /// used `NeuralVoice()` and never thought about audio graphs got an
    /// engine that ran for the life of the process — which on iOS means
    /// `setActive(false)` fails with `IsBusy` and the person's music
    /// never returns. The 4e review found it; the demo was fixed by
    /// owning its own host, and this closes it for everybody else.
    ///
    /// Safe to call more than once, and safe to call on a voice that
    /// never spoke.
    public func shutdown() {
        ownHost?.stopRendering()
        ownHost = nil
    }

    /// Renders replies on `host` from now on.
    ///
    /// Settable rather than fixed at init because the two lifetimes do
    /// not match: a capture session starts and stops every time someone
    /// taps Listen, while a 1.1 GB pipeline should be loaded once and
    /// kept. Rebuilding the voice to change where it speaks would pay
    /// for the model again on every tap.
    public func render(on host: any PlaybackHost) {
        providedHost = host
    }

    /// The seam (AC-101). One utterance, decoded by TTSKit and rendered
    /// by us, on whichever host the caller chose.
    public func openUtterance() async throws -> any SynthesisRun {
        let kit = try await loadedPipeline()
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
        // The vendor becomes a `TTSDecoding` here, and that is the whole of
        // the seam at this level (AC-109, D-053 F-6). Below this line
        // nothing names TTSKit's decode API; above it, the model lifecycle
        // still does, deliberately (F-7 = A).
        // `currentLead`, not `lead`: the second reply of a session is
        // cushioned by what the FIRST one measured on this machine.
        //
        // And the observer is always installed, even when nobody registered
        // a handler — margins used to be computed only if someone was
        // watching, and now the voice itself is always watching.
        let memory = adaptive
        let listener = marginHandler
        let onMargin: @Sendable (DecodeMargin) -> Void = { margin in
            memory.observe(margin)
            listener?(margin)
        }
        let run = try NeuralVoiceRun(decoder: TTSKitDecoder(kit: kit), host: host,
                                     lead: PlaybackLead(target: currentLead),
                                     temperature: temperature,
                                     onMargin: onMargin)
        speaking = run
        return run
    }

    /// Downloads the model if it is missing, then loads the pipeline.
    /// Idempotent: with the assets on disk this is a load, not a fetch.
    ///
    /// No progress callback, deliberately. The first draft of this method
    /// had one, and it was decoration: it reported 1.0 when the await
    /// returned and nothing before — a fake instrument in a repo whose
    /// whole method is refusing those. TTSKit's own `verbose` logging is
    /// the honest reporter until a real one is needed.
    /// Returns nothing on purpose: handing a `TTSKit` back would drag
    /// the dependency into every caller's imports, which is the opposite
    /// of what an opt-in module is for (D-045 F-4). The pipeline stays
    /// in here.
    public func ensureModel() async throws {
        // The holder does the caching now; this only asks for it.
        _ = try await loadedPipeline()
    }

    /// Loads once, then reuses. The variant's own logging reports the
    /// download; this only owns the caching.
    /// ONE load at a time — enforced, not assumed.
    ///
    /// FOUND IN THE FIELD, and it had been pointed out to me first. The
    /// 4h review's verifier wrote: "WhisperEngine.loadedPipeline and
    /// NeuralVoice.loadedPipeline share the same unguarded shape, but
    /// only the MLX path holds 2.2 GB." I fixed the MLX path and left
    /// these, on the size argument.
    ///
    /// Then Ryad's log showed the neural voice loading TWICE,
    /// concurrently — two tokenizers, two sets of six CoreML models,
    /// "Total model load: 82.26s" and "74.96s" — because an actor does
    /// NOT hold isolation across an await, so both callers passed the
    /// nil check. That is ~2.2 GB of CoreML instead of 1.1 GB, and it is
    /// the likeliest cause of the jetsam kill the pressure probe
    /// recorded (INSTRUMENTS §28).
    ///
    /// The shape is `decode`'s, one method over: a busy flag, a FIFO
    /// waiter queue, re-checked in a WHILE loop after every wake, and
    /// released on every exit through `defer`.
    private func loadedPipeline() async throws -> TTSKit {
        // THE PLATFORM SAYS NO BEFORE ANYTHING ELSE IS ASKED (AC-159).
        // The vendor documented this refusal and this project walked past
        // it into a raw CoreML "error code: -14" on Ryad's phone (SPEC
        // §117). Refusing HERE costs nothing: no folder touched, no
        // network, no counter moved.
        //
        // OUTERMOST on purpose, and the order is load-bearing: the
        // control test stands a retired voice one step behind this guard
        // as a tripwire — reaching `NeuralVoiceRetired` with a forced-true
        // verdict proves this guard passed it through, with zero loads.
        guard platformVerdict ?? variant.isAvailableOnCurrentPlatform else {
            throw NeuralVoiceUnavailableOnPlatform(variant: variant)
        }
        // A RETIRED VOICE NEVER LOADS AGAIN — that is what retiring MEANS.
        // Both `openUtterance()` and `ensureModel()` come through here, so
        // one guard closes both doors.
        guard !isRetired else { throw NeuralVoiceRetired() }
        // Read the configuration HERE, on the actor, so the build closure
        // captures values rather than isolated state.
        let model = variant
        let speech = speechDecoderMode
        let multi = multiCodeDecoderMode
        let requestedSeed = seed
        loadAttempts += 1
        let kit = try await held.value {
            try await TTSKit(TTSKitConfig(
                model: model,
                speechDecoderMode: speech,
                multiCodeDecoderMode: multi,
                download: true, load: true, seed: requestedSeed))
        }
        // THE REENTRANCY LAW. The await above released the actor, and a
        // caller already parked in the holder's queue passed the guard
        // before the retire landed. Re-check, throw away what it built, and
        // tell the truth rather than hand back a pipeline nobody tracks.
        guard !isRetired else {
            await held.retire()
            throw NeuralVoiceRetired()
        }
        return kit
    }

    /// Gives back the loaded models and the owned engine.
    ///
    /// AC-145. Changing a lever means building a NEW voice — the decoder and
    /// the vocoder mode are fixed at init, deliberately, so that the lead can
    /// be derived from them and cannot drift. Retiring the old one is how the
    /// phone ends up with exactly one pipeline resident instead of a pile.
    ///
    /// A load in flight when this is called will not install its result; that
    /// caller is told `retiredDuringLoad` rather than handed a voice nobody
    /// is tracking. Safe to call twice, and safe on a voice that never spoke.
    public func retire() async {
        // THE LATCH FIRST, in this actor step, BEFORE any await. Everything
        // below suspends, and a caller that arrives during a suspension must
        // already find a voice that says no.
        isRetired = true
        shutdown()
        // AND TAKE THE REPLY WITH IT (D-070). Without this the run keeps
        // itself alive through its drain task and holds the whole 1.1 GB
        // pipeline, so retiring frees nothing while the assistant is
        // speaking — which is exactly when a lever gets changed.
        let dying = speaking
        speaking = nil
        await dying?.cancel()
        await held.retire()
    }
}
