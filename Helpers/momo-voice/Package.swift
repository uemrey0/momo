// swift-tools-version: 6.0
import PackageDescription

// `momo-voice`, the helper process that runs Momo's open source, on-device live voice engine.
//
// It is a separate package so that Momo itself stays on macOS 14 with no third-party
// dependencies: the engine needs macOS 15, Apple Silicon and speech-swift (MLX + Core ML).
// MLX's Metal shaders need `xcodebuild`, not `swift build`.
let package = Package(
    name: "momo-voice",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "momo-voice", targets: ["momo-voice"])
    ],
    dependencies: [
        // The protocol shared with the app (the root Momo package).
        .package(name: "Momo", path: "../.."),
        // Pinned to a release tag; update deliberately and re-run the latency checks.
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.28"),
    ],
    targets: [
        // Pure logic with no audio or model dependencies, so it is fast to test.
        .target(
            name: "MomoVoiceCore",
            dependencies: [.product(name: "MomoLiveProtocol", package: "Momo")]
        ),
        // Audio devices, models and speech synthesis.
        .target(
            name: "MomoVoiceEngine",
            dependencies: [
                "MomoVoiceCore",
                .product(name: "MomoLiveProtocol", package: "Momo"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "NemotronStreamingASR", package: "speech-swift"),
                .product(name: "KokoroTTS", package: "speech-swift"),
                .product(name: "SupertonicTTS", package: "speech-swift"),
            ]
        ),
        .executableTarget(
            name: "momo-voice",
            dependencies: [
                "MomoVoiceCore", "MomoVoiceEngine",
                .product(name: "MomoLiveProtocol", package: "Momo"),
            ]
        ),
        .testTarget(
            name: "MomoVoiceCoreTests",
            dependencies: [
                "MomoVoiceCore", .product(name: "MomoLiveProtocol", package: "Momo"),
            ]
        ),
    ]
)
