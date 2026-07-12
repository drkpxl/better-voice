// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterVoice2",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Pinned to the tested revision (main as of 0.9.2); bump deliberately, not via branch tracking.
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "a95ec26ee05f19b5f6e69c62e1d4fae420537730"),
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
            name: "BetterVoice2",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                "BetterVoiceCore"
            ],
            path: "Sources",
            exclude: ["BetterVoiceCore"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.define("BENCH", .when(configuration: .debug))]
        ),
        .testTarget(
            name: "BetterVoiceCoreTests",
            dependencies: ["BetterVoiceCore"],
            path: "Tests/BetterVoiceCoreTests"
        )
    ]
)
