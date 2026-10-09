import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class CompatBadgeTests: XCTestCase {
    private func app(family: AppFamily) -> InspectedApp {
        InspectedApp(bundleURL: URL(fileURLWithPath: "/tmp/x.app"), bundleIdentifier: "x", name: "x", version: "1",
                     executableURL: URL(fileURLWithPath: "/tmp/x.app/Contents/MacOS/x"), family: family, isSandboxed: false,
                     iconFileURL: nil, isPlatformBinary: false, hasLaunchConstraints: false, lsEnvironment: [:], warnings: [])
    }

    func testBadges() {
        XCTAssertEqual(CompatBadge.badge(for: nil), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native)), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron)), .auto)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .chromium)), .auto)
    }

    func testLabels() {
        XCTAssertEqual(CompatBadge.verified.label, "Verified")
        XCTAssertEqual(CompatBadge.auto.label, "Auto")
        XCTAssertEqual(CompatBadge.homeOnly.label, "HOME only")
        XCTAssertEqual(CompatBadge.unsupported.label, "Unsupported")
        XCTAssertEqual(CompatBadge.unknown.label, "Unknown")
    }
}
