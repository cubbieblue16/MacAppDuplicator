// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacAppDuplicator",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DuplicatorCore", targets: ["DuplicatorCore"]),
        .library(name: "CompatProfiles", targets: ["CompatProfiles"]),
        .executable(name: "Launcher", targets: ["Launcher"]),
        .executable(name: "WebShell", targets: ["WebShell"]),
        .executable(name: "madctl", targets: ["madctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DuplicatorCore", path: "Packages/DuplicatorCore/Sources/DuplicatorCore"),
        .testTarget(name: "DuplicatorCoreTests", dependencies: ["DuplicatorCore"],
                    path: "Packages/DuplicatorCore/Tests/DuplicatorCoreTests"),
        // Compatibility profiles (spec §8). Linked by the app and its tests only; the Launcher never reads profiles.
        .target(name: "CompatProfiles", dependencies: ["DuplicatorCore"],
                path: "Packages/CompatProfiles/Sources/CompatProfiles"),
        .testTarget(name: "CompatProfilesTests", dependencies: ["CompatProfiles", "DuplicatorCore"],
                    path: "Packages/CompatProfiles/Tests/CompatProfilesTests"),
        .executableTarget(name: "Launcher", dependencies: ["DuplicatorCore"], path: "Launcher/Sources/Launcher"),
        // Web-app shortcut executable (Phase 4 skeleton decision 2). Programmatic AppKit + WebKit, no resources.
        .executableTarget(name: "WebShell", dependencies: ["DuplicatorCore"], path: "WebShell/Sources/WebShell"),
        .testTarget(name: "WebShellTests", dependencies: ["WebShell", "DuplicatorCore"], path: "WebShell/Tests/WebShellTests"),
        .executableTarget(name: "madctl",
                          dependencies: ["DuplicatorCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
                          path: "Tools/madctl/Sources/madctl"),
        .testTarget(name: "IntegrationTests", dependencies: ["DuplicatorCore"], path: "Tests/Integration"),
    ],
    swiftLanguageModes: [.v6]
)
