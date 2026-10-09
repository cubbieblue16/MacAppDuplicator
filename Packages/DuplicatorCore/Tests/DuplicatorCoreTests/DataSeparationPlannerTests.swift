import XCTest
@testable import DuplicatorCore

final class DataSeparationPlannerTests: XCTestCase {
    private let allFamilies: [AppFamily] = [.todesktop, .electron, .chromium, .firefox, .eclipse, .native]
    private let dataPath = "/Users/test/Library/Application Support/App Duplicator/target-work"
    private let baseEnvironment = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "LANG": "en_US.UTF-8"]

    private func app(
        _ family: AppFamily,
        sandboxed: Bool = false,
        platformBinary: Bool = false,
        launchConstrained: Bool = false
    ) -> InspectedApp {
        InspectedApp(
            bundleURL: URL(filePath: "/Applications/Target.app", directoryHint: .isDirectory),
            bundleIdentifier: "com.example.target",
            name: "Target",
            version: "1.0",
            executableURL: URL(filePath: "/Applications/Target.app/Contents/MacOS/Target", directoryHint: .notDirectory),
            family: family,
            isSandboxed: sandboxed,
            iconFileURL: nil,
            isPlatformBinary: platformBinary,
            hasLaunchConstraints: launchConstrained
        )
    }

    private func config(
        _ dataMode: DataMode,
        dataPath: String?? = .none,
        launchMode: LaunchMode = .dockShortcut,
        environment: [String: String] = [:],
        arguments: [String] = [],
        appearance: Appearance = .system,
        languageCode: String? = nil
    ) -> ShortcutConfig {
        ShortcutConfig(
            name: "Target Work",
            slug: "target-work",
            bundleIdentifier: "com.mikekuta.appduplicator.target-work",
            targetPath: "/Applications/Target.app",
            targetBundleIdentifier: "com.example.target",
            launchMode: launchMode,
            dataMode: dataMode,
            dataPath: dataPath ?? self.dataPath,
            environment: environment,
            arguments: arguments,
            appearance: appearance,
            languageCode: languageCode
        )
    }

    private func plan(_ app: InspectedApp, _ config: ShortcutConfig, shortcutBundleURL: URL? = nil) -> LaunchPlan {
        DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)
    }

    // MARK: Data modes (spec §4.3), every family × every mode

    private struct Expected {
        var arguments: [String] = []
        var directories: [String] = []
        var homeOverride = false
        var warnings: [String] = []
    }

    private func expectedAuto(_ family: AppFamily) -> Expected {
        switch family {
        case .todesktop, .electron, .chromium:
            return Expected(arguments: ["--user-data-dir=\(dataPath)"], directories: [dataPath])
        case .firefox:
            return Expected(arguments: ["--profile", dataPath, "--no-remote"], directories: [dataPath])
        case .eclipse:
            return Expected(
                arguments: ["-data", dataPath + "/workspace", "-configuration", dataPath + "/configuration"],
                directories: [dataPath, dataPath + "/workspace", dataPath + "/configuration"]
            )
        case .native:
            return Expected(directories: [dataPath], homeOverride: true, warnings: ["untested app; HOME override applied"])
        }
    }

    private func assertPlan(_ plan: LaunchPlan, _ expected: Expected, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.arguments, expected.arguments, label, file: file, line: line)
        XCTAssertEqual(plan.directoriesToCreate.map(\.path), expected.directories, label, file: file, line: line)
        XCTAssertEqual(plan.warnings, expected.warnings, label, file: file, line: line)
        if expected.homeOverride {
            XCTAssertEqual(plan.homeOverridePath?.path, dataPath, label, file: file, line: line)
            XCTAssertEqual(plan.environment["HOME"], dataPath, label, file: file, line: line)
            XCTAssertEqual(plan.environment["CFFIXED_USER_HOME"], dataPath, label, file: file, line: line)
        } else {
            XCTAssertNil(plan.homeOverridePath, label, file: file, line: line)
            XCTAssertEqual(plan.environment["HOME"], "/Users/test", label, file: file, line: line)
            XCTAssertNil(plan.environment["CFFIXED_USER_HOME"], label, file: file, line: line)
        }
        XCTAssertEqual(plan.launchMode, .dockShortcut, label, file: file, line: line)
        XCTAssertEqual(plan.executableURL.path, "/Applications/Target.app/Contents/MacOS/Target", label, file: file, line: line)
    }

    func testEveryFamilyInEveryDataMode() {
        for family in allFamilies {
            assertPlan(plan(app(family), config(.auto)), expectedAuto(family), "\(family) auto")
            assertPlan(
                plan(app(family), config(.homeOverride)),
                Expected(directories: [dataPath], homeOverride: true),
                "\(family) homeOverride"
            )
            assertPlan(plan(app(family), config(.disabled)), Expected(), "\(family) disabled")
        }
    }

    func testSandboxedNativeAppInAutoModeIsNotSeparated() {
        assertPlan(
            plan(app(.native, sandboxed: true), config(.auto)),
            Expected(warnings: ["sandboxed app; its container cannot be moved. Multiple instances may share data."]),
            "native sandboxed auto"
        )
    }

    func testSandboxedNativeAppStillGetsAnExplicitHomeOverride() {
        assertPlan(plan(app(.native, sandboxed: true), config(.homeOverride)), Expected(directories: [dataPath], homeOverride: true), "native sandboxed home")
    }

    func testMissingDataPathSkipsSeparationWithAWarning() {
        assertPlan(
            plan(app(.electron), config(.auto, dataPath: .some(nil))),
            Expected(warnings: ["Auto data separation needs a data path; data separation skipped."]),
            "auto without path"
        )
        assertPlan(
            plan(app(.native), config(.homeOverride, dataPath: .some(nil))),
            Expected(warnings: ["HOME override needs a data path; data separation skipped."]),
            "home without path"
        )
    }

    // MARK: Appearance and language (spec §4.5)

    func testLightAppearanceForEveryFamily() {
        for family in allFamilies {
            let arguments = plan(app(family), config(.disabled, appearance: .light)).arguments
            XCTAssertEqual(arguments, ["-NSRequiresAquaSystemAppearance", "YES"], "\(family)")
        }
    }

    func testDarkAppearanceForcesDarkModeOnlyForChromiumFamilies() {
        for family in [AppFamily.chromium, .electron, .todesktop] {
            let result = plan(app(family), config(.disabled, appearance: .dark))
            XCTAssertEqual(result.arguments, ["--force-dark-mode"], "\(family)")
            XCTAssertEqual(result.warnings, [], "\(family)")
        }
        for family in [AppFamily.firefox, .eclipse, .native] {
            let result = plan(app(family), config(.disabled, appearance: .dark))
            XCTAssertEqual(result.arguments, [], "\(family)")
            XCTAssertEqual(result.warnings, ["Dark override is not available for \(family.rawValue) apps"], "\(family)")
        }
    }

    func testAppleInterfaceStyleIsNeverEmitted() {
        for family in allFamilies {
            for appearance in [Appearance.system, .light, .dark] {
                let arguments = plan(app(family), config(.auto, appearance: appearance, languageCode: "de")).arguments
                XCTAssertFalse(arguments.contains { $0.contains("AppleInterfaceStyle") }, "\(family) \(appearance)")
            }
        }
    }

    func testSystemAppearanceAddsNothing() {
        XCTAssertEqual(plan(app(.electron), config(.disabled)).arguments, [])
    }

    func testLanguageOverride() {
        XCTAssertEqual(
            plan(app(.native), config(.disabled, languageCode: "de")).arguments,
            ["-AppleLanguages", "(de)", "-AppleLocale", "de"]
        )
        XCTAssertEqual(plan(app(.native), config(.disabled, languageCode: "")).arguments, [])
    }

    // MARK: Argument and environment order (spec §4.4)

    func testArgumentOrderIsPlannerThenAppearanceThenLanguageThenUser() {
        let result = plan(app(.chromium), config(.auto, arguments: ["--user-flag", "value with spaces"], appearance: .light, languageCode: "fr"))
        XCTAssertEqual(result.arguments, [
            "--user-data-dir=\(dataPath)",
            "-NSRequiresAquaSystemAppearance", "YES",
            "-AppleLanguages", "(fr)", "-AppleLocale", "fr",
            "--user-flag", "value with spaces",
        ])
    }

    func testEnvironmentPrecedenceAndShortcutVariables() {
        let base = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/test",
            "SHARED": "base",
            "MAD_INTERNAL_STATE": "launcher-only",
            "MAD_SHORTCUT_NAME": "stale",
        ]
        let shortcut = URL(filePath: "/Users/test/Applications/App Duplicator/Target Work.app", directoryHint: .isDirectory)
        let result = DataSeparationPlanner().plan(
            app: app(.native),
            config: config(.homeOverride, environment: ["SHARED": "shortcut", "EXTRA": "1"]),
            baseEnvironment: base,
            shortcutBundleURL: shortcut
        )
        XCTAssertEqual(result.environment, [
            "PATH": "/usr/bin:/bin",
            "HOME": dataPath,
            "CFFIXED_USER_HOME": dataPath,
            "SHARED": "shortcut",
            "EXTRA": "1",
            "MAD_SHORTCUT_NAME": "Target Work",
            "MAD_SHORTCUT_BUNDLE": "/Users/test/Applications/App Duplicator/Target Work.app",
        ])
    }

    func testUserEnvironmentWinsOverPlannerHome() {
        let result = plan(app(.native), config(.homeOverride, environment: ["HOME": "/custom/home"]))
        XCTAssertEqual(result.environment["HOME"], "/custom/home")
        XCTAssertEqual(result.environment["CFFIXED_USER_HOME"], dataPath)
    }

    func testPreviewWithoutShortcutBundleOmitsBundleVariable() {
        let result = plan(app(.electron), config(.disabled))
        XCTAssertEqual(result.environment["MAD_SHORTCUT_NAME"], "Target Work")
        XCTAssertNil(result.environment["MAD_SHORTCUT_BUNDLE"])
    }

    // MARK: Forced System Launch (spec §4.1)

    func testPlatformBinaryForcesSystemLaunch() {
        let result = plan(app(.native, sandboxed: true, platformBinary: true), config(.disabled))
        XCTAssertEqual(result.launchMode, .systemLaunch)
        XCTAssertEqual(result.warnings, [
            "Target is an Apple platform binary; Dock Shortcut mode is unavailable, so it starts through System Launch and owns its Dock tile.",
        ])
    }

    func testLaunchConstraintsForceSystemLaunch() {
        let result = plan(app(.native, launchConstrained: true), config(.disabled))
        XCTAssertEqual(result.launchMode, .systemLaunch)
        XCTAssertEqual(result.warnings, [
            "Target is launch-constrained; Dock Shortcut mode is unavailable, so it starts through System Launch and owns its Dock tile.",
        ])
    }

    func testChosenLaunchModeIsKeptOtherwise() {
        XCTAssertEqual(plan(app(.electron), config(.disabled, launchMode: .dockShortcut)).launchMode, .dockShortcut)
        XCTAssertEqual(plan(app(.electron), config(.disabled, launchMode: .systemLaunch)).launchMode, .systemLaunch)
    }

    func testTextEditIsForcedToSystemLaunch() throws {
        let path = "/System/Applications/TextEdit.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "TextEdit is not installed")
        let textEdit = try AppInspector().inspect(appAt: URL(filePath: path, directoryHint: .isDirectory))
        let result = DataSeparationPlanner().plan(app: textEdit, config: config(.auto), baseEnvironment: baseEnvironment)
        XCTAssertEqual(result.launchMode, .systemLaunch)
        XCTAssertEqual(result.warnings, [
            "TextEdit is an Apple platform binary; Dock Shortcut mode is unavailable, so it starts through System Launch and owns its Dock tile.",
            "sandboxed app; its container cannot be moved. Multiple instances may share data.",
        ])
    }

    // MARK: LaunchPlan helpers

    func testApplyingEffectiveHomeRewritesPlannedHomeOnly() {
        let planned = plan(app(.native), config(.homeOverride))
        let effective = URL(filePath: dataPath + "/mike", directoryHint: .isDirectory)
        let applied = planned.applyingEffectiveHome(effective)
        XCTAssertEqual(applied.environment["HOME"], dataPath + "/mike")
        XCTAssertEqual(applied.environment["CFFIXED_USER_HOME"], dataPath + "/mike")
        XCTAssertEqual(applied.homeOverridePath?.path, dataPath + "/mike")

        let custom = plan(app(.native), config(.homeOverride, environment: ["HOME": "/custom/home"])).applyingEffectiveHome(effective)
        XCTAssertEqual(custom.environment["HOME"], "/custom/home")
        XCTAssertEqual(custom.environment["CFFIXED_USER_HOME"], dataPath + "/mike")

        let disabled = plan(app(.native), config(.disabled))
        XCTAssertEqual(disabled.applyingEffectiveHome(effective), disabled)
    }

    func testEnvironmentAdditionsAreTheChangedAndNewVariables() {
        var result = plan(app(.native), config(.disabled))
        result.environment = ["A": "1", "B": "3", "C": "4"]
        XCTAssertEqual(result.environmentAdditions(relativeTo: ["A": "1", "B": "2", "D": "5"]), ["B": "3", "C": "4"])
    }
}
