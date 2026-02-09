// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Ripcord",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TranscribeKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/TranscribeKit"
        ),
        .executableTarget(
            name: "transcribe",
            dependencies: [
                "TranscribeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/transcribe"
        ),
        .executableTarget(
            name: "Ripcord",
            dependencies: ["TranscribeKit"],
            path: "Sources/Ripcord",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit"],
            path: "Tests/TranscribeKitTests"
        ),
    ]
)
