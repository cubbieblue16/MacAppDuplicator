import XCTest
@testable import DuplicatorCore

final class HelperPlanTests: XCTestCase {
    private static let dataPath = "/Users/test/Library/Application Support/App Duplicator/claude-work"

    private func makeConfig(
        kind: ShortcutKind = .app,
        dataMode: DataMode = .auto,
        dataPath: String? = HelperPlanTests.dataPath,
        eraseOnQuit: Bool = false,
        menuBarIcon: Bool = false
    ) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Claude Work",
            slug: "claude-work",
            bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Claude.app",
            targetBundleIdentifier: "com.anthropic.claudefordesktop",
            dataMode: dataMode,
            dataPath: dataPath,
            eraseOnQuit: eraseOnQuit,
            menuBarIcon: menuBarIcon
        )
    }

    func testOnlyApplicationShortcutsWithAMenuBarIconOrAnErasableFolderNeedAHelper() {
        XCTAssertTrue(HelperPlan.isNeeded(for: makeConfig(menuBarIcon: true)))
        XCTAssertTrue(HelperPlan.isNeeded(for: makeConfig(eraseOnQuit: true)))
        XCTAssertFalse(HelperPlan.isNeeded(for: makeConfig()))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            let config = makeConfig(kind: kind, eraseOnQuit: true, menuBarIcon: true)
            XCTAssertFalse(HelperPlan.isNeeded(for: config), kind.rawValue)
            XCTAssertNil(HelperPlan.eraseDataPath(for: config), kind.rawValue)
        }
    }

    func testEraseDataPathNeedsEraseOnQuitASeparatedModeAndAPath() {
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(eraseOnQuit: true)), Self.dataPath)
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(dataMode: .homeOverride, eraseOnQuit: true)), Self.dataPath)
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(eraseOnQuit: false)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataMode: .disabled, eraseOnQuit: true)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataPath: nil, eraseOnQuit: true)))
        XCTAssertNil(HelperPlan.eraseDataPath(for: makeConfig(dataPath: "", eraseOnQuit: true)))
        // The stored text passes through unchanged; EraseOnQuitPolicy refuses a relative path at run time.
        XCTAssertEqual(HelperPlan.eraseDataPath(for: makeConfig(dataPath: "relative/data", eraseOnQuit: true)), "relative/data")
    }

    func testDisabledDataSeparationLeavesOnlyTheMenuBarIcon() {
        XCTAssertFalse(HelperPlan.isNeeded(for: makeConfig(dataMode: .disabled, eraseOnQuit: true)))
        let withIcon = makeConfig(dataMode: .disabled, eraseOnQuit: true, menuBarIcon: true)
        XCTAssertTrue(HelperPlan.isNeeded(for: withIcon))
        XCTAssertNil(HelperPlan.eraseDataPath(for: withIcon))
    }
}
