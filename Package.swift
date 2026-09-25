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
    ],
    targets: [
        .target(name: "MomoFace"),
        .target(name: "MomoKit"),
        .target(name: "MomoBrain", dependencies: ["MomoKit"]),
        .executableTarget(
            name: "MomoApp",
            dependencies: ["MomoFace"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MomoFaceTests", dependencies: ["MomoFace"]),
        .testTarget(name: "MomoKitTests", dependencies: ["MomoKit"]),
    ]
)
