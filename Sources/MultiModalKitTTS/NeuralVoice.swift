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
/// WHAT ONE REPLY COST TO DECODE (AC-102/AC-104).
///
/// The Mac could read these off stderr. A phone cannot, and the phone is
/// where the question now lives: a field run reported the voice
/// "speaking in weird way like someone drunk", and the two leading
/// explanations — the decoder falling behind, or the audio playing at
/// the wrong rate — are told apart by numbers, not by adjectives.
public struct DecodeMargin: Sendable, Equatable {
    /// Audio produced, in milliseconds.
    public let audioMilliseconds: Double
    /// Wall time from the run's birth to its last decode step.
    public let wallMilliseconds: Double
    /// The first step's cost, paid once per reply.
    public let prefillMilliseconds: Double
    /// Decode wall time ÷ audio produced, measured from the FIRST step
    /// onward so the fixed prefill is not smeared across it. This is the
    /// number that says whether the machine can stream this voice.
    public let steadyRealTimeFactor: Double

    /// Below 1.0 the decoder runs ahead of the ear. At or above it, the
    /// player will run dry unless a lead was banked first.
    public var keepsUp: Bool { steadyRealTimeFactor < 1.0 }
    /// Whether the run FINISHED. A failed decode reports its margin too —
    /// the numbers are real — but its `audioMilliseconds` is however much
    /// audio existed when the throw happened, not a reply the conversation
    /// produced. The 4m review proved the consequence: an error-truncated
    /// length teaching the window that "replies are short" biases the
    /// cushion in exactly the under-banked direction 4m exists to fix.
    public let completed: Bool
    /// The cushion that was IN FORCE for this reply — the lead the run was
    /// BUILT with, stamped by the run itself. The 4n review proved why the
    /// consumer cannot ask the voice instead: the learner adapts from this
    /// very margin BEFORE any listener runs, so `currentLead` read in a
    /// margin handler is already the NEXT reply's cushion. On the exact
    /// session-start row §50 wants to convict, that misread logged a fat
    /// healthy cushion onto the one turn that ran starved. `nil` only for
    /// margins built outside a run (tests).
    public let cushionMilliseconds: Double?

    init(audioMilliseconds: Double, wallMilliseconds: Double,
         prefillMilliseconds: Double, steadyRealTimeFactor: Double,
         completed: Bool = true, cushionMilliseconds: Double? = nil) {
        self.audioMilliseconds = audioMilliseconds
        self.wallMilliseconds = wallMilliseconds
        self.prefillMilliseconds = prefillMilliseconds
        self.steadyRealTimeFactor = steadyRealTimeFactor
        self.completed = completed
        self.cushionMilliseconds = cushionMilliseconds
    }
}

public actor NeuralVoice: SpeechSynthesizing {
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

    /// The steady real-time factor MEASURED for the default decoder
    /// (AC-106: `.fused`, release build, M-series Mac, median of three
    /// runs on a long sentence). Below 1.0 means the decoder produces
    /// audio faster than the ear drinks it.
    ///
    /// Named rather than inlined because it is the one input the lead
    /// below is derived from: measure a slower machine, change this,
    /// and the cushion reappears without anyone having to remember why.
    /// The iPhone is NOT measured yet — that is AC-104.
    public nonisolated static let measuredRealTimeFactor = 0.752

    /// The default lead, DERIVED rather than picked (D-047).
    ///
    /// The sizing rule is `replyLength × (RTF − 1)`, and at 0.752 it
    /// returns **zero**: the decoder runs ahead of the ear, so there is
    /// no shortfall to bank and no reason to make anyone wait. That is
    /// why this is zero today — not a preference, an arithmetic result.
    ///
    /// It was 1500 ms while the default decoder was `.stepped` at RTF
    /// 1.066–1.25, and it cost first audio 227 ms → 1882 ms (§11).
    /// D-046 ruled to attack the decode as well as buy the cushion, and
    /// attacking it is what made the cushion unnecessary.
    ///
    /// DEPRECATED, and the deprecation is the fix. This constant sits
    /// beside `defaultLead(for:)` and reads like the safe choice, so
    /// `bakeoff voice-spike` passed it explicitly — and an explicit lead
    /// defeats the derivation by design. The instrument built to compare
    /// the decoders measured `--stepped` with `.fused`'s cushion of
    /// nothing, directly under the comment below warning about exactly
    /// that. A test could not catch it: the bug was in an executable's
    /// `main.swift`, which the package suite cannot reach. A deprecation
    /// can, because CI builds every target with warnings-as-errors.
    @available(*, deprecated, message: "This is .fused's cushion, not a universal default. Pass lead: nil to derive it from the decoder, or defaultLead(for:) to name a mode. Passing this to .stepped reintroduces the slow-voice bug.")
    public nonisolated static let defaultLead = PlaybackLead.deficit(
        forReplyOf: .seconds(6), realTimeFactor: measuredRealTimeFactor)

    /// THE LEAD MUST FOLLOW THE DECODER, and once it did not.
    ///
    /// `defaultLead` is derived from `measuredRealTimeFactor`, which is
    /// `.fused`'s 0.752 — below 1.0, so the deficit is zero and no cushion
    /// is banked. But the decoder mode is a SEPARATE parameter, and Swift
    /// cannot let one default argument read another. So a caller who asked
    /// for `.stepped` silently kept `.fused`'s cushion of nothing.
    ///
    /// It was measured immediately: `--mouth=neural` on a Mac, and the
    /// speech came out slow. RTF 1.066 means the decoder makes audio
    /// slower than the ear drinks it, so the player runs dry from the
    /// first buffer — which is D-046's finding, arriving again because the
    /// derivation was fed the wrong number.
    ///
    /// AC-106's measurements, per mode, so the rule can be applied rather
    /// than remembered.
    public nonisolated static func measuredRealTimeFactor(
        for mode: Qwen3MultiCodeDecoderMode
    ) -> Double {
        switch mode {
        case .fused: 0.752      // AC-106
        default: 1.066          // AC-106, `.stepped`
        }
    }

    /// The cushion this decoder actually needs, derived not guessed.
    public nonisolated static func defaultLead(
        for mode: Qwen3MultiCodeDecoderMode
    ) -> Duration {
        PlaybackLead.deficit(forReplyOf: .seconds(6),
                             realTimeFactor: measuredRealTimeFactor(for: mode))
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

    /// Where TTSKit's hub actually places this variant — MEASURED, not
    /// guessed. The first version of this property guessed
    /// `argmaxinc/tts-coreml/qwen3-tts-0.6b` and was wrong on both
    /// halves; the install printed "the load succeeded but the disk
    /// check says NOT installed", which is the message existing to
    /// catch exactly that.
    ///
    /// Named explicitly rather than left to the library's default, and
    /// that is a Phase 2 lesson rather than a preference: WhisperKit
    /// pinged Hugging Face on EVERY pipeline load until its
    /// `modelFolder` was handed over — an offline failure, a privacy
    /// footnote, and a 4× cost on every test load, all from a default.
    nonisolated var localModelFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/ttskit-coreml")
            .appending(path: "qwen3_tts")
    }

    /// The component directory each variant's weights live in
    /// (`code_decoder/12hz-0.6b-customvoice`, and five siblings).
    nonisolated var variantDirectoryName: String {
        switch variant {
        case .qwen3TTS_1_7b: "12hz-1.7b-customvoice"
        default: "12hz-0.6b-customvoice"
        }
    }

    /// The TOKENIZER, which lives in a different repo entirely
    /// (`Qwen/Qwen3-0.6B`) — 11 MB beside 1.1 GB of CoreML.
    ///
    /// Read from the VENDOR, not guessed (AC-160). The first version chose
    /// `Qwen3-1.7B` for the larger model, but TTSKit hard-wires ONE
    /// tokenizer repo for every variant — so this checked a folder TTSKit
    /// never fills, `modelInstalled()` could never say yes for 1.7B, and
    /// every attempt went to the network: the exact failure the Whisper
    /// audit named, rebuilt by the property whose comment below says it
    /// exists to prevent it (SPEC §118).
    nonisolated var localTokenizerFolder: URL {
        URL.documentsDirectory
            .appending(path: "huggingface/models")
            .appending(path: variant.tokenizerRepo)
    }

    /// Honest disk check — asking never triggers a download.
    ///
    /// "Installed" means OFFLINE-CAPABLE, and the Whisper audit's finding
    /// repeats here EXACTLY: the model folder alone is not enough,
    /// because the tokenizer is a separate asset in a separate repo whose
    /// absence sends the loader to the network. So this asks for all six
    /// CoreML components AND the tokenizer files by name. Anything less
    /// lets "installed" quietly mean "installed plus one download".
    public nonisolated func modelInstalled() async -> Bool {
        let files = FileManager.default
        let components = ["code_decoder", "code_embedder", "multi_code_decoder",
                          "multi_code_embedder", "speech_decoder", "text_projector"]
        for component in components {
            let path = localModelFolder
                .appending(path: component)
                .appending(path: variantDirectoryName)
            // NOT-EMPTY IS NOT INSTALLED, and a field report proved it.
            //
            // This used to accept any non-empty folder. A 1.1 GB download
            // interrupted over cellular leaves plenty of non-empty
            // folders, so the app reported the voice INSTALLED and then
            // failed to load it:
            //
            //   Error Domain=com.apple.CoreML Code=71
            //   "…/TextProjector.mlmodelc/model.mil:7:147: Error parsing"
            //
            // A truncated file is not a missing file, and a check that
            // cannot tell them apart sends a person hunting a memory bug
            // that does not exist. So: the compiled bundle must be there,
            // and the file CoreML actually parses must be non-trivial.
            // Cheap — a stat per component, no reading, no hashing — and
            // it catches truncation, which is the failure that happens.
            // FOUND, not assumed. The first version of this looked for the
            // .mlmodelc directly inside the variant folder and reported
            // every component broken — "loaded, but the disk check
            // disagrees" — while TTSKit had loaded the model perfectly.
            // The bundle sits one level deeper, under a QUANTISATION
            // folder whose name differs per component:
            //
            //   text_projector/12hz-0.6b-customvoice/W8A16/TextProjector.mlmodelc
            //   code_embedder/12hz-0.6b-customvoice/W16A16/CodeEmbedder.mlmodelc
            //
            // So it is searched for rather than constructed. Two wrongs in
            // one evening from the same habit: writing down where a file
            // OUGHT to be instead of asking where it IS.
            guard let walker = files.enumerator(at: path,
                                                includingPropertiesForKeys: nil),
                  let bundle = walker.compactMap({ $0 as? URL })
                      .first(where: { $0.pathExtension == "mlmodelc" })
            else { return false }
            let sizeOf: (String) -> Int = { name in
                (try? files.attributesOfItem(
                    atPath: bundle.appending(path: name).path)[.size] as? Int) ?? 0
            }
            // A truncated download leaves the folder present and the file
            // short, which is the failure that actually happens.
            guard sizeOf("model.mil") > 1_024 || sizeOf("coremldata.bin") > 1_024
            else { return false }
        }
        return files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer.json").path)
            && files.fileExists(atPath:
                localTokenizerFolder.appending(path: "tokenizer_config.json").path)
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
