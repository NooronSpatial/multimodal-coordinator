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
        .executable(name: "audio-demo", targets: ["AudioDemo"]),
        .executable(name: "bakeoff", targets: ["Bakeoff"]),
    ],
    dependencies: [
        // Tier 2 of the dependency policy (D-016): allowed because it lives
        // behind TranscriptionEngine and is removable in a day (D-023).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
    ],
    targets: [
        .target(name: "MultiModalKit"),
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
        .target(name: "MultiModalKitTesting", dependencies: ["MultiModalKit"]),
        .executableTarget(
            name: "AudioDemo",
            dependencies: ["MultiModalKit", "MultiModalKitWhisper"]
        ),
        .executableTarget(
            name: "Bakeoff",
            dependencies: [
                "MultiModalKit", "MultiModalKitTesting",
                "MultiModalKitWhisper", "MultiModalKitTTS",
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
            ]
        ),
    ]
)
