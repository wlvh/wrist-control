// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WristCore",
    platforms: [.macOS(.v13), .watchOS(.v9)],
    products: [.library(name: "WristCore", targets: ["WristCore"])],
    targets: [
        .target(name: "WristCore", path: "Shared/Sources/WristCore"),
        .target(name: "WristMacOutput", dependencies: ["WristCore"], path: "MacApp",
                exclude: ["App.swift", "MacBluetooth.swift", "Article.swift"],
                sources: ["SystemWheel.swift", "SystemPointer.swift", "DisplayGeometry.swift", "PointerCoordinator.swift", "CalibrationWindow.swift", "PracticeWindow.swift"]),
        .testTarget(name: "WristCoreTests", dependencies: ["WristCore", "WristMacOutput"], path: "Tests/WristCoreTests")
    ]
)
