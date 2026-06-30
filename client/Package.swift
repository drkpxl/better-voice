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
        .executableTarget(
            name: "WE",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
