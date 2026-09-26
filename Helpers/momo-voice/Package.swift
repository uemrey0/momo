// swift-tools-version: 6.0
import PackageDescription

// `momo-voice`, the helper process that runs Momo's open source, on-device live voice engine.
//
// It is a separate package so that Momo itself stays on macOS 14 with no third-party
// dependencies: the engine needs macOS 15 and Apple Silicon.
let package = Package(
    name: "momo-voice",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The protocol shared with the app (the root Momo package).
        .package(name: "Momo", path: "../..")
    ],
    targets: [
        // Pure logic with no audio or model dependencies, so it is fast to test.
        .target(
            name: "MomoVoiceCore",
            dependencies: [.product(name: "MomoLiveProtocol", package: "Momo")]
        ),
        .testTarget(
            name: "MomoVoiceCoreTests",
            dependencies: [
                "MomoVoiceCore", .product(name: "MomoLiveProtocol", package: "Momo"),
            ]
        ),
    ]
)
