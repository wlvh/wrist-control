// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WristCore",
    platforms: [.macOS(.v13), .watchOS(.v9)],
    products: [.library(name: "WristCore", targets: ["WristCore"])],
    targets: [
        .target(name: "WristCore", path: "Shared/Sources/WristCore"),
        .testTarget(name: "WristCoreTests", dependencies: ["WristCore"], path: "Tests/WristCoreTests")
    ]
)
