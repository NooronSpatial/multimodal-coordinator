// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "multimodal-coordinator",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
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
