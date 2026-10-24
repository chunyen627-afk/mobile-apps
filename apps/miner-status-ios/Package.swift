// swift-tools-version:5.9
import PackageDescription

// Pure, UI-free status core plus its XCTest suite. Tests read ../fixtures via #filePath, so they
// are meant for `swift test` / Xcode on a Mac checkout, not for an on-device test bundle.
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
