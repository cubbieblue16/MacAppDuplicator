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
            "dataPath", "environment", "arguments", "appearance", "languageCode", "eraseOnQuit", "menuBarIcon", "iconMode", "engineVersion",
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

    /// Final review M1: a slug names folders under the data root, so only `^[a-z0-9-]+$` is valid.
    func testIsValidSlugAcceptsOnlyLowercaseLettersDigitsAndHyphens() {
        for slug in ["claude-work", "chatgpt-2", "shortcut", "a", "0-9"] {
            XCTAssertTrue(ShortcutConfig.isValidSlug(slug), slug)
        }
        for slug in ["", "../escape", "Ok Name", "Claude", "a/b", "a.b", "..", "a_b", " a", "caf\u{E9}"] {
            XCTAssertFalse(ShortcutConfig.isValidSlug(slug), slug)
        }
        for name in ["Claude Work", "  Claude -- Personal!! ", "Café Zürich", "***"] {
            XCTAssertTrue(ShortcutConfig.isValidSlug(ShortcutConfig.slug(for: name)), name)
        }
    }

    /// Final review M1: decoding refuses a slug that fails `isValidSlug` with `configCorrupt("invalid slug")`.
    func testDecodingRefusesAnInvalidSlug() throws {
        for slug in ["../escape", "Ok Name"] {
            var dictionary = makeConfig().plistDictionary()
            dictionary["slug"] = slug
            XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary), slug) { error in
                guard case LauncherError.configCorrupt(let detail) = error else {
                    return XCTFail("expected configCorrupt for \(slug), got \(error)")
                }
                XCTAssertEqual(detail, "invalid slug")
            }
        }
        var valid = makeConfig().plistDictionary()
        valid["slug"] = "claude-work"
        XCTAssertEqual(try ShortcutConfig(plistDictionary: valid).slug, "claude-work")
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

    func testIconFieldsRoundTrip() throws {
        var config = makeConfig()
        config.iconMode = .custom
        config.customIconPath = "/Users/test/Pictures/work.png"
        config.homeSymlinkEntries = ["Desktop", ".ssh"]
        let decoded = try ShortcutConfig(plistDictionary: config.plistDictionary())
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.iconMode, .custom)
        XCTAssertEqual(decoded.customIconPath, "/Users/test/Pictures/work.png")
        XCTAssertEqual(decoded.homeSymlinkEntries, ["Desktop", ".ssh"])
    }

    func testEngineVersion1PlistWithoutIconFieldsDecodesWithDefaults() throws {
        // A Phase 1 MADConfig dictionary: no iconMode, customIconPath or homeSymlinkEntries keys.
        let legacy: [String: Any] = [
            "kind": "app", "name": "Claude Work", "slug": "claude-work",
            "bundleIdentifier": "com.mikekuta.appduplicator.claude-work",
            "targetPath": "/Applications/Claude.app", "targetBundleIdentifier": "com.anthropic.claudefordesktop",
            "launchMode": "dockShortcut", "dataMode": "auto",
            "environment": [String: String](), "arguments": [String](),
            "appearance": "system", "eraseOnQuit": false, "menuBarIcon": false, "engineVersion": 1,
        ]
        let config = try ShortcutConfig(plistDictionary: legacy)
        XCTAssertEqual(config.iconMode, .copied)
        XCTAssertNil(config.customIconPath)
        XCTAssertNil(config.homeSymlinkEntries)
        XCTAssertEqual(config.name, "Claude Work")
    }

    func testDefaultIconModeIsCopiedAndNilOptionalsAreOmitted() {
        let config = makeConfig()
        XCTAssertEqual(config.iconMode, .copied)
        let dictionary = config.plistDictionary()
        XCTAssertEqual(dictionary["iconMode"] as? String, "copied")
        XCTAssertNil(dictionary["customIconPath"])
        XCTAssertNil(dictionary["homeSymlinkEntries"])
    }

    func testConfigIsHashable() {
        let set: Set<ShortcutConfig> = [makeConfig(), makeConfig()]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: Launcher kinds (Phase 5)

    private func makeLauncherConfig(kind: ShortcutKind, file: FileConfig? = nil, cli: CLIConfig? = nil) -> ShortcutConfig {
        ShortcutConfig(
            kind: kind,
            name: "Projects",
            slug: "projects",
            bundleIdentifier: "com.mikekuta.appduplicator.projects",
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            file: file,
            cli: cli
        )
    }

    func testLauncherSubConfigsDefaultToNil() {
        let config = ShortcutConfig(name: "N", slug: "n", bundleIdentifier: "b", targetPath: "/A.app", targetBundleIdentifier: "a")
        XCTAssertNil(config.file)
        XCTAssertNil(config.cli)
        XCTAssertEqual(config.engineVersion, 1)
    }

    func testEveryKindRoundTripsThroughMADConfig() throws {
        let webApp = ShortcutConfig(
            kind: .webApp, name: "Mail", slug: "mail", bundleIdentifier: "com.mikekuta.appduplicator.mail",
            targetPath: "", targetBundleIdentifier: "", dataMode: .disabled, webApp: WebAppConfig(url: "https://mail.example.com")
        )
        let configs = [
            makeConfig(),
            webApp,
            makeLauncherConfig(kind: .file, file: FileConfig(path: "/Users/test/Notes.md", openerAppPath: "/Applications/TextEdit.app")),
            makeLauncherConfig(kind: .folder, file: FileConfig(path: "/Users/test/Projects")),
            makeLauncherConfig(
                kind: .cli,
                cli: CLIConfig(
                    executablePath: "/usr/bin/top",
                    arguments: ["-o", "cpu"],
                    workingDirectory: "~",
                    terminal: .iterm2,
                    homeOverride: true
                )
            ),
        ]
        for config in configs {
            XCTAssertEqual(try ShortcutConfig(plistDictionary: config.plistDictionary()), config, "kind \(config.kind)")
        }
    }

    func testLauncherSubConfigsAreWrittenOnlyWhenSet() throws {
        let folder = makeLauncherConfig(kind: .folder, file: FileConfig(path: "/Users/test/Projects")).plistDictionary()
        XCTAssertEqual(folder["kind"] as? String, "folder")
        XCTAssertEqual((folder["file"] as? [String: Any])?["path"] as? String, "/Users/test/Projects")
        XCTAssertNil(folder["cli"])
        XCTAssertNil(folder["webApp"])
        XCTAssertNil(folder["dataPath"])
        XCTAssertEqual(folder["targetPath"] as? String, "")
        XCTAssertEqual(folder["engineVersion"] as? Int, 1)

        let command = makeLauncherConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls", terminal: TerminalChoice.none))
        let dictionary = command.plistDictionary()
        let cli = try XCTUnwrap(dictionary["cli"] as? [String: Any])
        XCTAssertEqual(cli["executablePath"] as? String, "/bin/ls")
        XCTAssertEqual(cli["arguments"] as? [String], [])
        XCTAssertEqual(cli["terminal"] as? String, "none")
        XCTAssertEqual(cli["homeOverride"] as? Bool, false)
        XCTAssertNil(cli["workingDirectory"])
        XCTAssertNil(dictionary["file"])

        XCTAssertNil(makeConfig().plistDictionary()["file"])
        XCTAssertNil(makeConfig().plistDictionary()["cli"])
    }

    func testCorruptLauncherSubConfigThrowsConfigCorrupt() {
        var dictionary = makeLauncherConfig(kind: .cli, cli: CLIConfig(executablePath: "/bin/ls")).plistDictionary()
        dictionary["cli"] = ["arguments": ["-l"]]
        XCTAssertThrowsError(try ShortcutConfig(plistDictionary: dictionary)) { error in
            guard case LauncherError.configCorrupt = error else {
                return XCTFail("expected configCorrupt, got \(error)")
            }
        }
    }
}
