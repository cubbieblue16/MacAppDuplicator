import XCTest
@testable import DuplicatorCore

final class ShortcutConfigTests: XCTestCase {
    private func makeConfig() -> ShortcutConfig {
        ShortcutConfig(
            kind: .app,
            name: "Claude Work",
            slug: "claude-work",
            bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Claude.app",
            targetBundleIdentifier: "com.anthropic.claudefordesktop",
            launchMode: .systemLaunch,
            dataMode: .homeOverride,
            dataPath: "/Users/test/Library/Application Support/App Duplicator/claude-work",
            environment: ["API_TOKEN": "not-a-real-token", "PLAIN": "1"],
            arguments: ["--flag", "value with spaces"],
            appearance: .dark,
            languageCode: "de",
            eraseOnQuit: true,
            menuBarIcon: true,
            engineVersion: 1
        )
    }

    func testPlistDictionaryRoundTrips() throws {
        let config = makeConfig()
        XCTAssertEqual(try ShortcutConfig(plistDictionary: config.plistDictionary()), config)
    }

    func testPlistDictionaryUsesFieldNamesAndRawValues() {
        let dictionary = makeConfig().plistDictionary()
        XCTAssertEqual(Set(dictionary.keys), [
            "kind", "name", "slug", "bundleIdentifier", "targetPath", "targetBundleIdentifier", "launchMode", "dataMode",
            "dataPath", "environment", "arguments", "appearance", "languageCode", "eraseOnQuit", "menuBarIcon", "engineVersion",
        ])
        XCTAssertEqual(dictionary["kind"] as? String, "app")
        XCTAssertEqual(dictionary["launchMode"] as? String, "systemLaunch")
        XCTAssertEqual(dictionary["dataMode"] as? String, "homeOverride")
        XCTAssertEqual(dictionary["appearance"] as? String, "dark")
        XCTAssertEqual(dictionary["engineVersion"] as? Int, 1)
        XCTAssertEqual(dictionary["environment"] as? [String: String], ["API_TOKEN": "not-a-real-token", "PLAIN": "1"])
        XCTAssertEqual(dictionary["arguments"] as? [String], ["--flag", "value with spaces"])
    }

    func testNilOptionalsAreOmittedAndTheDictionaryIsAPropertyList() throws {
        var config = makeConfig()
        config.dataPath = nil
        config.languageCode = nil
        let dictionary = config.plistDictionary()
        XCTAssertNil(dictionary["dataPath"])
        XCTAssertNil(dictionary["languageCode"])
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
        XCTAssertEqual(try ShortcutConfig(plistDictionary: dictionary), config)
    }

    func testInitializerDefaults() {
        let config = ShortcutConfig(name: "N", slug: "n", bundleIdentifier: "b", targetPath: "/A.app", targetBundleIdentifier: "a")
        XCTAssertEqual(config.kind, .app)
        XCTAssertEqual(config.launchMode, .dockShortcut)
        XCTAssertEqual(config.dataMode, .auto)
        XCTAssertNil(config.dataPath)
        XCTAssertEqual(config.environment, [:])
        XCTAssertEqual(config.arguments, [])
        XCTAssertEqual(config.appearance, .system)
        XCTAssertNil(config.languageCode)
        XCTAssertFalse(config.eraseOnQuit)
        XCTAssertFalse(config.menuBarIcon)
        XCTAssertEqual(config.engineVersion, 1)
        XCTAssertEqual(ShortcutConfig.currentEngineVersion, 1)
        XCTAssertEqual(ShortcutConfig.infoPlistKey, "MADConfig")
        XCTAssertEqual(ShortcutConfig.engineVersionInfoPlistKey, "MADEngineVersion")
    }

    func testCorruptDictionariesThrowConfigCorrupt() {
        var missingName = makeConfig().plistDictionary()
        missingName.removeValue(forKey: "name")
        var wrongType = makeConfig().plistDictionary()
        wrongType["engineVersion"] = "one"
        var unknownKind = makeConfig().plistDictionary()
        unknownKind["kind"] = "spaceship"
        for dictionary in [missingName, wrongType, unknownKind] {
            XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary)) { error in
                guard case LauncherError.configCorrupt = error else {
                    return XCTFail("expected configCorrupt, got \(error)")
                }
            }
        }
    }

    func testSlugLowercasesAndCollapsesEverythingElseToSingleHyphens() {
        XCTAssertEqual(ShortcutConfig.slug(for: "Claude Work"), "claude-work")
        XCTAssertEqual(ShortcutConfig.slug(for: "  Claude -- Personal!! "), "claude-personal")
        XCTAssertEqual(ShortcutConfig.slug(for: "ChatGPT 2"), "chatgpt-2")
        XCTAssertEqual(ShortcutConfig.slug(for: "Café Zürich"), "caf-z-rich")
        XCTAssertEqual(ShortcutConfig.slug(for: "***"), "shortcut")
    }

    func testBundleIdentifierAndDefaultDataPath() {
        XCTAssertEqual(ShortcutConfig.bundleIdentifier(forSlug: "claude-work"), "com.mikekuta.appduplicator.claude-work")
        XCTAssertEqual(
            ShortcutConfig.defaultDataPath(forSlug: "claude-work", home: URL(filePath: "/Users/test", directoryHint: .isDirectory)),
            "/Users/test/Library/Application Support/App Duplicator/claude-work"
        )
    }

    func testFileSystemNameReplacesPathSeparators() {
        XCTAssertEqual(ShortcutConfig.fileSystemName(for: "Claude Work"), "Claude Work")
        XCTAssertEqual(ShortcutConfig.fileSystemName(for: "Work/Personal: 2"), "Work-Personal- 2")
        XCTAssertEqual(ShortcutConfig.fileSystemName(for: "   "), "Shortcut")
    }
}
