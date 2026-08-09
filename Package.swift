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
        .executable(name: "audio-demo", targets: ["AudioDemo"]),
    ],
    targets: [
        .target(name: "MultiModalKit"),
        .executableTarget(
            name: "AudioDemo",
            dependencies: ["MultiModalKit"]
        ),
        .testTarget(
            name: "MultiModalKitTests",
            dependencies: ["MultiModalKit"]
        ),
    ]
)
