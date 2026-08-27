// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "multimodal-coordinator",
    platforms: [
        // Phase 2 floor (D-017): Apple's SpeechAnalyzer/SpeechTranscriber
        // ship with OS 26. The bump is deliberate and logged.
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "MultiModalKit", targets: ["MultiModalKit"]),
        // The gift, separated (D-022): deterministic fakes for consumers'
        // own tests — ManualClock, FakeMicrophone, ScriptedTranscriber —
        // without shipping a single test double inside the core product.
        .library(name: "MultiModalKitTesting", targets: ["MultiModalKitTesting"]),
        // The second engine (D-017, D-023): OPT-IN. The core keeps zero
        // runtime dependencies; only consumers who import this product pull
        // WhisperKit.
        .library(name: "MultiModalKitWhisper", targets: ["MultiModalKitWhisper"]),
        // The second MOUTH (D-045 F-4): opt-in for the same reason, and
        // its OWN product rather than a corner of the Whisper module —
        // it implements a different seam, and an app that wants a voice
        // should not be made to pull a speech recogniser.
        .library(name: "MultiModalKitTTS", targets: ["MultiModalKitTTS"]),
        // The second MIND (D-062 F-1 = A): opt-in, for the same reason the
        // second ear and the second mouth are. D-061 closed the gate that
        // let this line exist at all — MLX runs under `swift test` with a
        // metallib present, and on CI whose runner already ships the
        // toolchain. It does NOT run on the iOS Simulator, structurally.
        .library(name: "MultiModalKitMLX", targets: ["MultiModalKitMLX"]),
        // The BENCH (D-067 F-1 = A): the sweep's invariants — wait for
        // readiness not for time, reset per row, restore what the human
        // chose — live here so they can be TESTED on a Mac with no models.
        // Zero dependencies, including on this package's own targets: it
        // knows about rows, not about decoders.
        .library(name: "MultiModalKitBench", targets: ["MultiModalKitBench"]),
        .executable(name: "audio-demo", targets: ["AudioDemo"]),
        .executable(name: "bakeoff", targets: ["Bakeoff"]),
    ],
    dependencies: [
        // Tier 2 of the dependency policy (D-016): allowed because it lives
        // behind TranscriptionEngine and is removable in a day (D-023).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
        // Tier 2 again (D-016), priced in the open (D-062 F-5 = A): this
        // pulls mlx-swift, and swift-syntax for macro expansion — a slow
        // BUILD-time cost, never a runtime one. Removable in a day because
        // it lives behind `ReplyGenerating` in a product nobody imports
        // unless they want it.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
        // The tokenizer, which mlx-swift-lm deliberately does NOT ship
        // (D-062 F-5 = A): it provides `#huggingFaceTokenizerLoader()`, a
        // macro that wraps YOUR `Tokenizers.Tokenizer`. The spike proved a
        // hand-rolled one yields ids that are valid but WRONG, so this is
        // the third package, paid for in the open.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // DECLARED, NOT BORROWED (D-016, and the review that caught it).
        //
        // `MultiModalKitMLX` calls `MLX.Memory.cacheLimit` directly — that
        // is OUR call, not something inherited — but `MLX` was never named
        // here. It compiled only because mlx-swift-lm happens to expose it
        // transitively, which is the arrangement D-016 forbids and the same
        // one the test target was already corrected for: "DECLARED, not
        // borrowed … an undeclared dependency that compiles until the
        // search path tightens."
        //
        // No new package ENTERS the graph: mlx-swift is already resolved as
        // mlx-swift-lm's own dependency. This names what we were already
        // using, so a version bump upstream cannot silently take it away.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.0"),
    ],
    targets: [
        .target(name: "MultiModalKit"),
        .target(
            name: "MultiModalKitBench",
            // The core only, for `SpeechSynthesizing` — the stopwatch times
            // a mouth, and there is no way to time one without naming it.
            // Still nothing about decoders, CoreML or SwiftUI.
            dependencies: ["MultiModalKit"]
        ),
        .target(
            name: "MultiModalKitWhisper",
            dependencies: [
                "MultiModalKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(
            name: "MultiModalKitTTS",
            dependencies: [
                "MultiModalKit",
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(
            name: "MultiModalKitMLX",
            dependencies: [
                "MultiModalKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // The macro that bridges swift-transformers' tokenizer into
                // MLX's own protocol. This is what pulls swift-syntax — a
                // BUILD-time cost only, measured in INSTRUMENTS §25.
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                // `MLX.Memory.cacheLimit` — a PROCESS-GLOBAL setting this
                // module writes deliberately (D-027's policy note lives on
                // that line). Ours to name.
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
                // `Hub` — the snapshot API the weights download goes
                // through. Same package as Transformers, and imported
                // directly, so it is listed directly.
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .target(name: "MultiModalKitTesting", dependencies: ["MultiModalKit"]),
        .executableTarget(
            name: "AudioDemo",
            // Every organ, so the Mac can mix ear/mind/mouth from a
            // terminal the way the phone demo does from pickers. A DEMO
            // target, tier 2 of D-016 — the core still knows none of this.
            dependencies: [
                "MultiModalKit", "MultiModalKitWhisper",
                "MultiModalKitTTS", "MultiModalKitMLX",
                // Direct, so `--decoder=` / `--speech=` can name the modes
                // they switch, exactly as `bakeoff voice-levers` does.
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "Bakeoff",
            dependencies: [
                "MultiModalKit", "MultiModalKitTesting",
                "MultiModalKitWhisper", "MultiModalKitTTS",
                // The second mind, so `mind-off` can put the two brains on
                // the same question (AC-130).
                "MultiModalKitMLX",
                // The bench's measuring types — `cushion-sweep` reads
                // `DigitalSilence` from here rather than carrying its own
                // copy, because the metric must be the SAME one the tests
                // pin (4o, AC-178).
                "MultiModalKitBench",
                // Direct, so `voice-levers` can name the decoder modes it
                // is comparing (AC-106). A TOOL target, tier 2 of D-016 —
                // the core still knows nothing about any of this.
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "MultiModalKitTests",
            dependencies: [
                "MultiModalKit", "MultiModalKitTesting",
                "MultiModalKitWhisper", "MultiModalKitTTS",
                "MultiModalKitMLX", "MultiModalKitBench",
                // DECLARED, not borrowed. `SynthesizerConformanceTests`
                // imports TTSKit to name `.stepped` and `.fused`, and that
                // import worked only through transitive module visibility —
                // an undeclared dependency that compiles until the search
                // path tightens. The Bakeoff target declares it for the same
                // reason (above); tests get the same honesty.
                .product(name: "TTSKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
)
