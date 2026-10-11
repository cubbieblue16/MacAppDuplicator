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

    func testMenuBarIconShowsOnlyForApplicationShortcuts() {
        XCTAssertTrue(HelperPlan.showsMenuBarIcon(for: makeConfig(menuBarIcon: true)))
        XCTAssertTrue(HelperPlan.showsMenuBarIcon(for: makeConfig(dataMode: .disabled, menuBarIcon: true)))
        XCTAssertFalse(HelperPlan.showsMenuBarIcon(for: makeConfig(eraseOnQuit: true)))
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            XCTAssertFalse(HelperPlan.showsMenuBarIcon(for: makeConfig(kind: kind, menuBarIcon: true)), kind.rawValue)
        }
    }

    func testNewWindowArgumentsUseTheResolvedTargetAndTheDataFolder() {
        var config = makeConfig()
        config.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath} --bundle={bundleId}"
        XCTAssertEqual(
            HelperPlan.newWindowArguments(for: config, targetPath: "/Applications/Moved/Claude.app"),
            [
                "/usr/bin/env", "open", "-na", "/Applications/Moved/Claude.app", "--args",
                "--user-data-dir=\(Self.dataPath)", "--bundle=com.anthropic.claudefordesktop",
            ]
        )
    }

    func testNewWindowArgumentsAreNilWithoutATemplateOrWithoutTheDataFolderTheTemplateNames() {
        XCTAssertNil(HelperPlan.newWindowArguments(for: makeConfig(), targetPath: "/Applications/Claude.app"))
        var disabled = makeConfig(dataMode: .disabled)
        disabled.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath}"
        XCTAssertNil(HelperPlan.newWindowArguments(for: disabled, targetPath: "/Applications/Claude.app"))
        var emptyPath = makeConfig(dataPath: "")
        emptyPath.newWindowCommand = "open -na {target} --args --user-data-dir={dataPath}"
        XCTAssertNil(HelperPlan.newWindowArguments(for: emptyPath, targetPath: "/Applications/Claude.app"))
        // A template without {dataPath} still works when data separation is disabled.
        disabled.newWindowCommand = "open -na {target}"
        XCTAssertEqual(
            HelperPlan.newWindowArguments(for: disabled, targetPath: "/Applications/Claude.app"),
            ["/usr/bin/env", "open", "-na", "/Applications/Claude.app"]
        )
    }

    func testNewWindowArgumentsAreNilForOtherKinds() {
        for kind in [ShortcutKind.webApp, .file, .folder, .cli] {
            var config = makeConfig(kind: kind)
            config.newWindowCommand = "open -na {target}"
            XCTAssertNil(HelperPlan.newWindowArguments(for: config, targetPath: "/Applications/Claude.app"), kind.rawValue)
        }
    }
}
