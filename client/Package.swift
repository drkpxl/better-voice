// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WE",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main")
    ],
    targets: [
        // Foundation-only pure-logic library so it can be unit-tested without the
        // macOS 26 Speech/ScreenCaptureKit/FluidAudio surface or TCC permissions.
        .target(
            name: "WECore",
            path: "Sources/WECore"
        ),
        .executableTarget(
            name: "WE",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "WECore"
            ],
            path: "Sources",
            exclude: ["WECore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "WECoreTests",
            dependencies: ["WECore"],
            path: "Tests/WECoreTests"
        )
    ]
)
