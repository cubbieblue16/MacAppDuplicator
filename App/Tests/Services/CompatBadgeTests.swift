import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class CompatBadgeTests: XCTestCase {
    private func app(family: AppFamily, sandboxed: Bool = false) -> InspectedApp {
        InspectedApp(bundleURL: URL(fileURLWithPath: "/tmp/x.app"), bundleIdentifier: "x", name: "x", version: "1",
                     executableURL: URL(fileURLWithPath: "/tmp/x.app/Contents/MacOS/x"), family: family, isSandboxed: sandboxed,
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

    func testProfileStatusComesBeforeTheFamily() {
        let verified = AppProfile(name: "X", status: .verified)
        let partial = AppProfile(name: "X", status: .partial, family: .electron)
        let unsupported = AppProfile(name: "X", status: .unsupported)
        // A profile that marks the app single-instance wins over every family, native included.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: unsupported), .unsupported)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron), profile: unsupported), .unsupported)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: verified), .verified)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .chromium), profile: verified), .verified)
        // A partial profile says nothing about the badge; the detected family decides.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native), profile: partial), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .firefox), profile: partial), .auto)
        // Without an inspected app there is nothing to badge, whatever the profile says.
        XCTAssertEqual(CompatBadge.badge(for: nil, profile: verified), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: nil, profile: unsupported), .unknown)
    }

    func testSandboxedNativeAppIsUnknown() {
        // Final review M9: a sandboxed app's container ignores a HOME override, so `HOME only` would promise too much.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: true)), .unknown)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: false)), .homeOnly)
        XCTAssertEqual(CompatBadge.badge(for: app(family: .electron, sandboxed: true)), .auto)
        // A profile still decides first.
        XCTAssertEqual(CompatBadge.badge(for: app(family: .native, sandboxed: true), profile: AppProfile(name: "X", status: .verified)), .verified)
    }

    /// A web app has no target app, so there is nothing to badge (skeleton decision 14).
    func testBadgeIsShownOnlyForShortcutsThatHaveATarget() {
        XCTAssertTrue(CompatBadge.isShown(for: .app))
        XCTAssertFalse(CompatBadge.isShown(for: .webApp))
    }

    func testWizardCaptionSpellsOutUnknownAndKeepsOtherLabels() {
        XCTAssertEqual(TargetStep.targetCaption(name: "TextEdit", version: "1.21", badge: .unknown), "TextEdit 1.21 · No compatibility profile")
        XCTAssertEqual(TargetStep.targetCaption(name: "Slack", version: "4", badge: .verified), "Slack 4 · Verified")
        XCTAssertEqual(TargetStep.targetCaption(name: "Notes", version: "4", badge: .homeOnly), "Notes 4 · HOME only")
        XCTAssertEqual(CompatBadge.unknown.label, "Unknown", "the sidebar and detail view keep the short label")
    }
}
