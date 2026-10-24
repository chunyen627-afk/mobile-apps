// swift-tools-version:5.9
import PackageDescription

// Optional: run the UI-free core and its XCTest suite with `swift test` on a Mac checkout.
// scripts/build.sh and CI use project.yml (simulator tests) instead. Tests read ../fixtures
// via #filePath, so they are not meant for an on-device test bundle.
let package = Package(
    name: "MinerStatus",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MinerStatusCore", targets: ["MinerStatusCore"]),
    ],
    targets: [
        .target(name: "MinerStatusCore"),
        .testTarget(name: "MinerStatusCoreTests", dependencies: ["MinerStatusCore"]),
    ]
)
