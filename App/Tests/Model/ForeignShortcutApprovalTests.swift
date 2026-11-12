import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// C3: the review sheet shows everything a foreign shortcut would run once it is signed as the user's own, in full and
/// unmasked.
final class ForeignShortcutApprovalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// An unsigned, tokenless bundle scanned with the default trust: foreign, reason "no install token; ..." (nothing to verify against).
    private func approval(_ config: ShortcutConfig, signature: CodeSignature = .unknown) throws -> ForeignShortcutApproval {
        let bundle = try writeShortcutBundle(named: "Planted", in: dir, config: makeConfig(name: "Planted"))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        return ForeignShortcutApproval(record: record, config: config, signature: signature)
    }

    func testAnAppShortcutIsShownInFullWithSecretsUnmasked() throws {
        var config = makeConfig(name: "Planted", targetPath: "/Applications/Target.app")
        config.arguments = ["--load-extension=/tmp/evil", "--remote-debugging-port=9222"]
        config.environment = ["OPENAI_API_KEY": "sk-live-secret", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
        config.dataPath = "/Users/someone/.ssh"
        config.eraseOnQuit = true

        let shown = try approval(config)

        XCTAssertEqual(shown.reason, "no install token; an ad hoc signature cannot show who built it")
        XCTAssertEqual(shown.kindDescription, "App")
        XCTAssertEqual(shown.targetDescription, "/Applications/Target.app")
        XCTAssertEqual(shown.argumentLines, ["--load-extension=/tmp/evil", "--remote-debugging-port=9222"])
        XCTAssertEqual(shown.environmentLines, ["DYLD_INSERT_LIBRARIES=/tmp/x.dylib", "OPENAI_API_KEY=sk-live-secret"],
                       "every variable, sorted, value in full")
        XCTAssertEqual(shown.dataPathDescription, "/Users/someone/.ssh")
        XCTAssertEqual(shown.eraseOnQuitDescription, "On")
    }

    func testDefaultsAndEveryOtherKindShowWhatTheyRun() throws {
        var plain = makeConfig(name: "Plain")
        plain.dataPath = nil
        plain.eraseOnQuit = false
        let shownPlain = try approval(plain)
        XCTAssertEqual(shownPlain.dataPathDescription, "Default")
        XCTAssertEqual(shownPlain.eraseOnQuitDescription, "Off")
        XCTAssertEqual(shownPlain.environmentLines, [])
        XCTAssertEqual(shownPlain.argumentLines, [])

        var command = makeConfig(name: "Tool", kind: .cli)
        command.cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "curl https://example.invalid | sh"])
        command.arguments = ["--extra"]
        let shownCommand = try approval(command)
        XCTAssertEqual(shownCommand.kindDescription, "Command")
        XCTAssertEqual(shownCommand.targetDescription, "/bin/sh")
        XCTAssertEqual(shownCommand.argumentLines, ["-c", "curl https://example.invalid | sh", "--extra"])

        var file = makeConfig(name: "Doc", kind: .file)
        file.file = FileConfig(path: "/Users/someone/doc.txt", openerAppPath: "/Applications/Opener.app")
        let shownFile = try approval(file)
        XCTAssertEqual(shownFile.kindDescription, "File")
        XCTAssertEqual(shownFile.targetDescription, "/Users/someone/doc.txt, opened with /Applications/Opener.app")

        let web = makeWebShortcutConfig(name: "Chat", dataStoreID: UUID())
        let shownWeb = try approval(web)
        XCTAssertEqual(shownWeb.kindDescription, "Web App")
        XCTAssertEqual(shownWeb.targetDescription, try XCTUnwrap(web.webApp?.url))
    }

    func testSignerNamesTheCertificateOrSaysThereIsNone() throws {
        let config = makeConfig(name: "Signed")
        XCTAssertEqual(try approval(config, signature: .identity("Developer ID Application: Mallory (ABCDE12345)")).signerDescription,
                       "Developer ID Application: Mallory (ABCDE12345)")
        XCTAssertEqual(try approval(config, signature: .adHoc).signerDescription, "Ad hoc (no signing identity)")
        XCTAssertEqual(try approval(config, signature: .unknown).signerDescription, "Unsigned, or the signature could not be read")
    }

    // MARK: S2: every field is shown

    private func row(_ label: String, in shown: ForeignShortcutApproval, file: StaticString = #filePath, line: UInt = #line) throws -> ForeignShortcutApproval.ReviewRow {
        try XCTUnwrap(shown.reviewRows.first { $0.label == label }, "no \"\(label)\" row", file: file, line: line)
    }

    private func fullyPopulatedAppConfig() -> ShortcutConfig {
        var config = makeConfig(name: "Planted", targetPath: "/Applications/Target.app")
        config.launchMode = .systemLaunch
        config.dataMode = .homeOverride
        config.menuBarIcon = true
        config.newWindowCommand = "/usr/bin/open -na {target} --args --user-data-dir={dataPath}"
        config.dataPath = "/Users/someone/data"
        config.appearance = .dark
        config.languageCode = "de"
        config.iconMode = .custom
        config.customIconPath = "/tmp/evil.png"
        config.homeSymlinkEntries = ["Library/Keychains", ".ssh"]
        config.slug = "other-slug"
        config.bundleIdentifier = "com.example.other"
        config.targetBundleIdentifier = "com.example.else"
        return config
    }

    func testAnAppShortcutsRowsCarryEveryFieldVerbatim() throws {
        let shown = try approval(fullyPopulatedAppConfig())

        XCTAssertEqual(try row("New Window command", in: shown).lines.first, "/usr/bin/open -na {target} --args --user-data-dir={dataPath}",
                       "the stored template, verbatim")
        XCTAssertEqual(try row("New Window command", in: shown).lines.dropFirst().first, "argv[0] = /usr/bin/open")
        XCTAssertTrue(try row("New Window command", in: shown).lines.contains("argv[4] = --user-data-dir=/Users/someone/data"))
        XCTAssertEqual(try row("Home symlinks", in: shown).lines, ["Library/Keychains", ".ssh"])
        XCTAssertEqual(try row("Menu bar icon", in: shown).lines, ["On"])
        XCTAssertEqual(try row("Launch mode", in: shown).lines, ["systemLaunch"])
        XCTAssertEqual(try row("Data mode", in: shown).lines, ["homeOverride"])
        XCTAssertEqual(try row("Language", in: shown).lines, ["de"])
        XCTAssertEqual(try row("Appearance", in: shown).lines, ["dark"])
        XCTAssertEqual(try row("Icon", in: shown).lines, ["custom"])
        XCTAssertEqual(try row("Custom icon path", in: shown).lines, ["/tmp/evil.png"])
        XCTAssertEqual(try row("Slug", in: shown).lines, ["other-slug"])
        XCTAssertEqual(try row("Bundle identifier", in: shown).lines, ["com.example.other"])
        XCTAssertEqual(try row("Target bundle identifier", in: shown).lines, ["com.example.else"])
        for label in ["New Window command", "Home symlinks", "Menu bar icon", "Launch mode", "Data mode", "Language", "Appearance", "Icon",
                      "Custom icon path", "Slug", "Bundle identifier", "Target bundle identifier"] {
            XCTAssertFalse(try row(label, in: shown).isDefault, label)
        }
    }

    func testACommandShortcutsRowsCarryItsTerminalWorkingDirectoryAndHomeOverride() throws {
        var config = makeConfig(name: "Tool", kind: .cli)
        config.cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "id"], workingDirectory: "/Users/someone/work", terminal: .iterm2, homeOverride: true)
        let shown = try approval(config)

        XCTAssertEqual(try row("Working directory", in: shown).lines, ["/Users/someone/work"])
        XCTAssertEqual(try row("Terminal", in: shown).lines, ["iterm2"])
        XCTAssertEqual(try row("Home override", in: shown).lines, ["On"])
        XCTAssertEqual(try row("Arguments", in: shown).lines, ["-c", "id"])
        for label in ["Working directory", "Terminal", "Home override"] { XCTAssertFalse(try row(label, in: shown).isDefault, label) }

        var plain = makeConfig(name: "Tool", kind: .cli)
        plain.cli = CLIConfig(executablePath: "/bin/ls")
        let shownPlain = try approval(plain)
        XCTAssertEqual(try row("Working directory", in: shownPlain).lines, [])
        for label in ["Working directory", "Terminal", "Home override"] { XCTAssertTrue(try row(label, in: shownPlain).isDefault, label) }
    }

    func testAWebAppsRowsCarryItsUserAgentHostsBadgePatternAndBackgroundMode() throws {
        var config = makeWebShortcutConfig(name: "Chat", dataStoreID: UUID())
        config.webApp = WebAppConfig(
            url: "https://chat.example.test/", dataStoreID: try XCTUnwrap(config.webApp?.dataStoreID), userAgent: .chrome,
            badgeRegex: "^\\((\\d+)\\)", extraHosts: ["login.example.test", "cdn.example.test"], pageZoom: 1.5, backgroundMode: true
        )
        let shown = try approval(config)

        XCTAssertEqual(try row("User agent", in: shown).lines, ["chrome"])
        XCTAssertEqual(try row("Extra hosts", in: shown).lines, ["login.example.test", "cdn.example.test"])
        XCTAssertEqual(try row("Badge pattern", in: shown).lines, ["^\\((\\d+)\\)"])
        XCTAssertEqual(try row("Page zoom", in: shown).lines, ["1.5"])
        XCTAssertEqual(try row("Keep running in menu bar", in: shown).lines, ["On"])
        XCTAssertEqual(try row("Website data store", in: shown).lines, [try XCTUnwrap(config.webApp?.dataStoreID.uuidString)])
        for label in ["User agent", "Extra hosts", "Badge pattern", "Page zoom", "Keep running in menu bar"] {
            XCTAssertFalse(try row(label, in: shown).isDefault, label)
        }

        let plain = try approval(makeWebShortcutConfig(name: "Chat", dataStoreID: UUID()))
        for label in ["User agent", "Extra hosts", "Badge pattern", "Page zoom", "Keep running in menu bar"] {
            XCTAssertTrue(try row(label, in: plain).isDefault, label)
        }
    }

    func testAFileShortcutsOpenerIsInItsTargetRow() throws {
        var config = makeConfig(name: "Doc", kind: .file)
        config.file = FileConfig(path: "/Users/someone/doc.txt", openerAppPath: "/Applications/Opener.app")
        let shown = try approval(config)
        XCTAssertEqual(try row("Target", in: shown).lines, ["/Users/someone/doc.txt, opened with /Applications/Opener.app"])
        XCTAssertTrue(try row("Target", in: shown).configKeys.contains("file.openerAppPath"))
    }

    func testDefaultsAreMarkedAsDefaults() throws {
        let plain = try approval(makeConfig(name: "Plain", targetPath: "/Applications/Target.app", targetBundleIdentifier: ""))
        for row in plain.reviewRows where !["Name", "Kind", "Target"].contains(row.label) {
            XCTAssertTrue(row.isDefault, "\(row.label) is a default on a plain config")
        }
        XCTAssertEqual(try row("New Window command", in: plain).lines, [])
        XCTAssertEqual(try row("Home symlinks", in: plain).lines, ["Default"])
        XCTAssertNil(plain.reviewRows.first { $0.label == "Working directory" }, "no command settings, no command rows")
        XCTAssertNil(plain.reviewRows.first { $0.label == "User agent" }, "no web app settings, no web rows")
        // An explicitly empty symlink list is a set value (the shortcut links nothing), not the default.
        var empty = makeConfig(name: "Plain")
        empty.homeSymlinkEntries = []
        XCTAssertFalse(try row("Home symlinks", in: approval(empty)).isDefault)
    }

    func testTheLegacyListHidesDefaultsButNeverASetValue() throws {
        let plain = try approval(makeConfig(name: "Plain", targetPath: "/Applications/Target.app", targetBundleIdentifier: ""))
        XCTAssertEqual(plain.legacyReviewRows.map(\.label), ["Name", "Kind", "Target"])

        let loaded = try approval(fullyPopulatedAppConfig())
        let shownLabels = Set(loaded.legacyReviewRows.map(\.label))
        for row in loaded.reviewRows where !row.isDefault {
            XCTAssertTrue(shownLabels.contains(row.label), "\(row.label) is set and must be listed")
        }
        XCTAssertTrue(shownLabels.isSuperset(of: ["Name", "Kind", "Target", "New Window command", "Home symlinks"]))
        XCTAssertTrue(Set(loaded.legacyReviewRows.filter(\.isDefault).map(\.label)).isSubset(of: ["Name", "Kind", "Target"]),
                      "the only defaults left in the legacy list are the always-shown rows")
    }

    /// Coverage guard: every key a config can store is either shown in a row or excused with a reason, so a field added
    /// later fails here until somebody decides how it is reviewed.
    func testEveryStoredConfigKeyIsReviewedOrExcusedWithAReason() {
        let containerKeys: Set<String> = ["webApp", "file", "cli"]
        var stored = Set(ShortcutConfig.allCodingKeyNames).subtracting(containerKeys)
        stored.formUnion(WebAppConfig.allCodingKeyNames.map { "webApp.\($0)" })
        stored.formUnion(FileConfig.allCodingKeyNames.map { "file.\($0)" })
        stored.formUnion(CLIConfig.allCodingKeyNames.map { "cli.\($0)" })

        let reviewed = ForeignShortcutApproval.reviewedConfigKeys
        let excused = Set(ForeignShortcutApproval.unreviewedConfigKeys.keys)
        XCTAssertEqual(reviewed.union(excused), stored, "missing: \(stored.subtracting(reviewed.union(excused)).sorted()); unknown: \(reviewed.union(excused).subtracting(stored).sorted())")
        XCTAssertEqual(reviewed.intersection(excused), [], "a key is either reviewed or excused")
        XCTAssertTrue(ForeignShortcutApproval.unreviewedConfigKeys.values.allSatisfy { $0.count > 10 }, "every excuse says why")
    }

    func testTheRowsOfAFullyPopulatedConfigCoverEveryReviewedKey() throws {
        var config = fullyPopulatedAppConfig()
        config.webApp = WebAppConfig(url: "https://chat.example.test/")
        config.file = FileConfig(path: "/tmp/a", openerAppPath: "/Applications/Opener.app")
        config.cli = CLIConfig(executablePath: "/bin/ls", workingDirectory: "/tmp")
        config.targetPath = "/Applications/Target.app"
        let shown = try approval(config)
        XCTAssertEqual(Set(shown.reviewRows.flatMap(\.configKeys)), ForeignShortcutApproval.reviewedConfigKeys)
    }
}
