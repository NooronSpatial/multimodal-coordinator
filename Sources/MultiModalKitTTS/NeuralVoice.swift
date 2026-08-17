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
    private var pipeline: TTSKit?

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
    public nonisolated static let defaultLead = PlaybackLead.deficit(
        forReplyOf: .seconds(6), realTimeFactor: measuredRealTimeFactor)

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

    public init(variant: TTSModelVariant = .qwen3TTS_0_6b,
                renderingOn host: (any PlaybackHost)? = nil,
                lead: Duration = NeuralVoice.defaultLead,
                multiCodeDecoderMode: Qwen3MultiCodeDecoderMode = .fused,
                speechDecoderMode: Qwen3SpeechDecoderMode = .latencyOptimized,
                temperature: Float? = nil,
                seed: UInt64? = nil) {
        self.variant = variant
        self.providedHost = host
        self.lead = lead
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
        return try NeuralVoiceRun(kit: kit, host: host,
                                  sampleRate: Double(kit.sampleRate),
                                  lead: PlaybackLead(target: lead),
                                  temperature: temperature,
                                  onMargin: marginHandler)
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
    nonisolated var localTokenizerFolder: URL {
        let repo = variant == .qwen3TTS_1_7b ? "Qwen3-1.7B" : "Qwen3-0.6B"
        return URL.documentsDirectory
            .appending(path: "huggingface/models/Qwen")
            .appending(path: repo)
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
            guard let contents = try? files.contentsOfDirectory(atPath: path.path),
                  !contents.isEmpty
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
        pipeline = try await loadedPipeline()
    }

    /// Loads once, then reuses. The variant's own logging reports the
    /// download; this only owns the caching.
    private func loadedPipeline() async throws -> TTSKit {
        if let pipeline { return pipeline }
        let fresh = try await TTSKit(TTSKitConfig(
            model: variant,
            speechDecoderMode: speechDecoderMode,
            multiCodeDecoderMode: multiCodeDecoderMode,
            download: true, load: true, seed: seed))
        pipeline = fresh
        return fresh
    }
}
