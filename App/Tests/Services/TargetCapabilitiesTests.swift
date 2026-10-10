import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// The editor and wizard availability rules must match what `DataSeparationPlanner` does at launch (spec §4.1, §4.5).
final class TargetCapabilitiesTests: XCTestCase {
    private static let allFamilies: [AppFamily] = [.todesktop, .electron, .chromium, .firefox, .eclipse, .native]

    private func app(family: AppFamily, platformBinary: Bool = false, launchConstraints: Bool = false) -> InspectedApp {
        InspectedApp(
            bundleURL: URL(fileURLWithPath: "/nonexistent/T.app"), bundleIdentifier: "com.example.t", name: "T", version: "1",
            executableURL: URL(fileURLWithPath: "/nonexistent/T.app/Contents/MacOS/T"), family: family, isSandboxed: false,
            iconFileURL: nil, isPlatformBinary: platformBinary, hasLaunchConstraints: launchConstraints
        )
    }

    func testForcedDarkAvailabilityMatchesThePlanner() {
        var config = makeConfig()
        config.appearance = .dark
        for family in Self.allFamilies {
            let plan = DataSeparationPlanner().plan(app: app(family: family), config: config, baseEnvironment: [:])
            XCTAssertEqual(plan.arguments.contains("--force-dark-mode"), family.supportsForcedDarkMode, "\(family)")
        }
        XCTAssertEqual(Set(Self.allFamilies.filter(\.supportsForcedDarkMode)), [.chromium, .electron, .todesktop])
    }

    func testDockShortcutAvailabilityMatchesThePlanner() {
        var config = makeConfig()
        config.launchMode = .dockShortcut
        for (platformBinary, launchConstraints) in [(false, false), (true, false), (false, true), (true, true)] {
            let target = app(family: .electron, platformBinary: platformBinary, launchConstraints: launchConstraints)
            let plan = DataSeparationPlanner().plan(app: target, config: config, baseEnvironment: [:])
            let label = "platformBinary \(platformBinary), launchConstraints \(launchConstraints)"
            XCTAssertEqual(plan.launchMode == .systemLaunch, target.requiresSystemLaunch, label)
            XCTAssertEqual(target.dockShortcutUnavailableReason != nil, target.requiresSystemLaunch, label)
        }
    }

    func testUnavailableReasonNamesTheCause() throws {
        let platform = try XCTUnwrap(app(family: .native, platformBinary: true).dockShortcutUnavailableReason)
        XCTAssertTrue(platform.contains("Apple platform binary"), platform)
        let constrained = try XCTUnwrap(app(family: .electron, launchConstraints: true).dockShortcutUnavailableReason)
        XCTAssertTrue(constrained.contains("launch-constrained"), constrained)
        XCTAssertNil(app(family: .electron).dockShortcutUnavailableReason)
    }
}
