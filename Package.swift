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
        .package(url: "https://github.com/unthingable/FluidAudio.git", branch: "feat/hypothesis-windows"),
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
            dependencies: [
                "TranscribeKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Ripcord",
            exclude: ["docs"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "usb-audio-capture",
            path: "Sources/usb-audio-capture",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
            ]
        ),
        .executableTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit"],
            path: "Tests/TranscribeKitTests"
        ),
        .testTarget(
            name: "RegressionTests",
            dependencies: ["TranscribeKit", "Ripcord"],
            path: "Tests/RegressionTests"
        ),
    ]
)
