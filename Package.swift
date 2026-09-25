// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Momo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Momo", targets: ["MomoApp"]),
        .library(name: "MomoFace", targets: ["MomoFace"]),
    ],
    targets: [
        .target(name: "MomoFace"),
        .executableTarget(
            name: "MomoApp",
            dependencies: ["MomoFace"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MomoFaceTests", dependencies: ["MomoFace"]),
    ]
)
