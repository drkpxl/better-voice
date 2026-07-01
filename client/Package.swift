// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterVoice",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Foundation-only pure-logic library so it can be unit-tested without the
        // macOS 26 Speech/ScreenCaptureKit/FluidAudio surface or TCC permissions.
        .target(
            name: "BetterVoiceCore",
            path: "Sources/BetterVoiceCore"
        ),
        .executableTarget(
            name: "BetterVoice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                "BetterVoiceCore"
            ],
            path: "Sources",
            exclude: ["BetterVoiceCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BetterVoiceCoreTests",
            dependencies: ["BetterVoiceCore"],
            path: "Tests/BetterVoiceCoreTests"
        )
    ]
)
