import XCTest
@testable import DuplicatorCore

final class BundleWriterWebAppTests: XCTestCase {
    private let fileManager = FileManager.default
    private let storeID = UUID(uuidString: "5B0D2C1E-8F3A-4C57-9E11-2A6D4B7C9F10")!

    private func webConfig(name: String = "WhatsApp", environment: [String: String] = ["LANG": "en_US.UTF-8", "TZ": "UTC"]) -> ShortcutConfig {
        ShortcutConfig(
            kind: .webApp,
            name: name,
            slug: ShortcutConfig.slug(for: name),
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: ShortcutConfig.slug(for: name)),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            environment: environment,
            menuBarIcon: true,
            webApp: WebAppConfig(
                url: "https://web.whatsapp.com", dataStoreID: storeID, userAgent: .chrome,
                badgeRegex: #"\((\d+)\)"#, extraHosts: ["whatsapp.net"], pageZoom: 1.25, backgroundMode: true
            )
        )
    }

    private struct Fixture {
        var output: URL
        var executable: URL
        var icon: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTemporaryDirectory()
        let executable = root.appending(path: "webshell-binary", directoryHint: .notDirectory)
        try Data("webshell".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        let icon = root.appending(path: "icon.icns", directoryHint: .notDirectory)
        try Data([7, 7, 7]).write(to: icon)
        return Fixture(output: root.appending(path: "out", directoryHint: .isDirectory), executable: executable, icon: icon)
    }

    private func readPlist(_ bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testLayoutCopiesTheExecutableWith755() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)

        XCTAssertEqual(bundle.path, fixture.output.appending(path: "WhatsApp.app", directoryHint: .isDirectory).path)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        let executable = contents.appending(path: "MacOS/WhatsApp", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: executable), Data("webshell".utf8))
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: contents.appending(path: "PkgInfo")), Data("APPL????".utf8))
        let icon = contents.appending(path: "Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([7, 7, 7]))
        XCTAssertThrowsError(try fileManager.destinationOfSymbolicLink(atPath: icon.path), "the icon must be a copy, not a symlink")
        let raw = try Data(contentsOf: contents.appending(path: "Info.plist", directoryHint: .notDirectory))
        XCTAssertEqual(Array(raw.prefix(5)), Array("<?xml".utf8), "Info.plist must be XML format")
    }

    func testInfoPlistValuesAndMADConfig() throws {
        let fixture = try makeFixture()
        let config = webConfig()
        let plist = try readPlist(BundleWriter().write(config: config, executable: fixture.executable, iconFile: fixture.icon, to: fixture.output))

        XCTAssertEqual(plist["CFBundleName"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.mikekuta.appduplicator.whatsapp")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "WhatsApp")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(plist["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertEqual(plist["MADEngineVersion"] as? Int, 1)
        let stored = try XCTUnwrap(plist["MADConfig"] as? [String: Any])
        let decoded = try ShortcutConfig(plistDictionary: stored)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.webApp?.dataStoreID, storeID)
    }

    func testKeySetMatchesTheAppShortcutWriter() throws {
        let root = try makeTemporaryDirectory()
        var target = FixtureBundle()
        target.info = ["CFBundleIconFile": "AppIcon", "LSEnvironment": ["A": "target"]]
        target.files = ["Resources/AppIcon.icns"]
        let targetBundle = try target.write(in: root)
        let app = try AppInspector().inspect(appAt: targetBundle)
        let fixture = try makeFixture()
        let appConfig = ShortcutConfig(
            name: "Claude Work", slug: "claude-work", bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Claude.app", targetBundleIdentifier: "com.example.fixture"
        )

        let appBundle = try BundleWriter().write(config: appConfig, app: app, launcherBinary: fixture.executable, iconFile: fixture.icon, to: fixture.output)
        let webBundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)

        let baseKeys: Set<String> = [
            "CFBundleName", "CFBundleDisplayName", "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
            "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "NSHighResolutionCapable",
            "LSEnvironment", "MADConfig", "MADEngineVersion", "CFBundleIconFile",
        ]
        XCTAssertEqual(Set(try readPlist(webBundle).keys), Set(try readPlist(appBundle).keys))
        XCTAssertEqual(Set(try readPlist(webBundle).keys), baseKeys)

        // Launcher kinds use the same writer. Only a command shortcut adds the Automation prompt text, because only it
        // can drive Terminal.app or iTerm2 through Apple Events (spec §6).
        let fileConfig = ShortcutConfig(
            kind: .file, name: "Notes", slug: "notes", bundleIdentifier: "com.mikekuta.appduplicator.notes",
            targetPath: "", targetBundleIdentifier: "", dataMode: .disabled, file: FileConfig(path: "/tmp/Notes.md")
        )
        let cliConfig = ShortcutConfig(
            kind: .cli, name: "Projects", slug: "projects", bundleIdentifier: "com.mikekuta.appduplicator.projects",
            targetPath: "", targetBundleIdentifier: "", dataMode: .disabled,
            cli: CLIConfig(executablePath: "/bin/echo", terminal: .terminal)
        )
        let fileBundle = try BundleWriter().write(config: fileConfig, executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)
        let cliBundle = try BundleWriter().write(config: cliConfig, executable: fixture.executable, iconFile: fixture.icon, to: fixture.output)
        XCTAssertEqual(Set(try readPlist(fileBundle).keys), baseKeys)
        let cliPlist = try readPlist(cliBundle)
        XCTAssertEqual(Set(cliPlist.keys), baseKeys.union(["NSAppleEventsUsageDescription"]))
        XCTAssertEqual(cliPlist["NSAppleEventsUsageDescription"] as? String, "Projects opens your terminal to run its command.")
    }

    /// The library app stamps its per-install token so a later scan can tell bundles it wrote from bundles that merely
    /// carry a `MADConfig` (security C3). A writer without a token (madctl) writes no key at all.
    func testInstallTokenIsStampedOnlyWhenGiven() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(ShortcutConfig.installTokenInfoPlistKey, "MADInstallToken")

        let stamped = try readPlist(BundleWriter(installToken: "abc123").write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertEqual(stamped[ShortcutConfig.installTokenInfoPlistKey] as? String, "abc123")

        let plain = try readPlist(BundleWriter().write(config: webConfig(name: "Plain"), executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertNil(plain[ShortcutConfig.installTokenInfoPlistKey])
    }

    func testLSEnvironmentIsExactlyTheConfigEnvironment() throws {
        let fixture = try makeFixture()
        let config = webConfig(environment: ["LANG": "de_DE.UTF-8", "API_TOKEN": "not-a-real-token"])
        let plist = try readPlist(BundleWriter().write(config: config, executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertEqual(plist["LSEnvironment"] as? [String: String], config.environment)

        let empty = webConfig(name: "Empty Env", environment: [:])
        let emptyPlist = try readPlist(BundleWriter().write(config: empty, executable: fixture.executable, iconFile: nil, to: fixture.output))
        XCTAssertEqual(emptyPlist["LSEnvironment"] as? [String: String], [:])
    }

    func testForbiddenKeysAreNeverWritten() throws {
        let fixture = try makeFixture()
        let keys = try readPlist(BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)).keys
        for forbidden in BundleWriter.forbiddenInfoPlistKeys {
            XCTAssertFalse(keys.contains(forbidden), "\(forbidden) must not be written")
        }
    }

    func testNilIconWritesNoIcon() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)
        XCTAssertNil(try readPlist(bundle)["CFBundleIconFile"])
        XCTAssertFalse(fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let missing = fixture.output.appending(path: "no-such.icns", directoryHint: .notDirectory)
        let second = try BundleWriter().write(config: webConfig(name: "Second"), executable: fixture.executable, iconFile: missing, to: fixture.output)
        XCTAssertNil(try readPlist(second)["CFBundleIconFile"], "a missing icon file is skipped, as for app shortcuts")
    }

    func testRewriteReplacesTheBundleAndLeavesNoStaging() throws {
        let fixture = try makeFixture()
        let writer = BundleWriter()
        let first = try writer.write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)
        try Data("webshell-v2".utf8).write(to: fixture.executable)
        let second = try writer.write(config: webConfig(), executable: fixture.executable, iconFile: nil, to: fixture.output)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second.appending(path: "Contents/MacOS/WhatsApp")), Data("webshell-v2".utf8))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.output.path), ["WhatsApp.app"])
    }

    func testMissingExecutableThrowsAndLeavesNothingBehind() throws {
        let fixture = try makeFixture()
        let missing = fixture.executable.deletingLastPathComponent().appending(path: "absent", directoryHint: .notDirectory)
        XCTAssertThrowsError(try BundleWriter().write(config: webConfig(), executable: missing, iconFile: nil, to: fixture.output))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: fixture.output.path), [])
    }

    func testSlashInNameBecomesDashInTheBundleAndExecutable() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: webConfig(name: "Work/Chat"), executable: fixture.executable, iconFile: nil, to: fixture.output)
        XCTAssertEqual(bundle.lastPathComponent, "Work-Chat.app")
        XCTAssertTrue(fileManager.fileExists(atPath: bundle.appending(path: "Contents/MacOS/Work-Chat").path))
        let plist = try readPlist(bundle)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Work-Chat")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Work/Chat")
    }
}
