// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Momo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Momo", targets: ["MomoApp"]),
        .library(name: "MomoFace", targets: ["MomoFace"]),
        .library(name: "MomoKit", targets: ["MomoKit"]),
        .library(name: "MomoBrain", targets: ["MomoBrain"]),
        .library(name: "MomoVoice", targets: ["MomoVoice"]),
    ],
    targets: [
        .target(name: "MomoFace"),
        .target(name: "MomoKit"),
        .target(name: "MomoBrain", dependencies: ["MomoKit"]),
        .target(name: "MomoVoice"),
        .executableTarget(
            name: "MomoApp",
            dependencies: ["MomoFace", "MomoKit", "MomoBrain", "MomoVoice"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MomoFaceTests", dependencies: ["MomoFace"]),
        .testTarget(name: "MomoKitTests", dependencies: ["MomoKit"]),
        .testTarget(name: "MomoBrainTests", dependencies: ["MomoBrain", "MomoKit"]),
        .testTarget(name: "MomoVoiceTests", dependencies: ["MomoVoice"]),
    ]
)
