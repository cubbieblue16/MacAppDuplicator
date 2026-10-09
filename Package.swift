// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacAppDuplicator",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DuplicatorCore", targets: ["DuplicatorCore"]),
        .executable(name: "Launcher", targets: ["Launcher"]),
        .executable(name: "madctl", targets: ["madctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DuplicatorCore", path: "Packages/DuplicatorCore/Sources/DuplicatorCore"),
        .testTarget(name: "DuplicatorCoreTests", dependencies: ["DuplicatorCore"],
                    path: "Packages/DuplicatorCore/Tests/DuplicatorCoreTests"),
        .executableTarget(name: "Launcher", dependencies: ["DuplicatorCore"], path: "Launcher/Sources/Launcher"),
        .executableTarget(name: "madctl",
                          dependencies: ["DuplicatorCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
                          path: "Tools/madctl/Sources/madctl"),
        .testTarget(name: "IntegrationTests", path: "Tests/Integration"),
    ],
    swiftLanguageModes: [.v6]
)
