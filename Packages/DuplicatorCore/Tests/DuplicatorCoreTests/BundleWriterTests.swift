import XCTest
@testable import DuplicatorCore

final class BundleWriterTests: XCTestCase {
    private let fileManager = FileManager.default

    private struct Fixture {
        var output: URL
        var launcher: URL
        var app: InspectedApp
    }

    private func config(name: String = "Claude Work") -> ShortcutConfig {
        ShortcutConfig(
            name: name,
            slug: "claude-work",
            bundleIdentifier: "com.mikekuta.appduplicator.claude-work",
            targetPath: "/Applications/Target.app",
            targetBundleIdentifier: "com.example.fixture",
            environment: ["B": "shortcut", "C": "shortcut"]
        )
    }

    /// A target with an icon (bytes `[1, 2, 3]`) and `LSEnvironment` `A`, `B`; plus a launcher file and an output directory.
    private func makeFixture(withIcon: Bool = true, launcherText: String = "launcher") throws -> Fixture {
        let root = try makeTemporaryDirectory()
        var target = FixtureBundle()
        if withIcon {
            target.info = ["CFBundleIconFile": "AppIcon", "LSEnvironment": ["A": "target", "B": "target"]]
            target.files = ["Resources/AppIcon.icns"]
        } else {
            target.info = ["LSEnvironment": ["A": "target", "B": "target"]]
        }
        let targetBundle = try target.write(in: root)
        if withIcon {
            try Data([1, 2, 3]).write(to: targetBundle.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory))
        }
        let app = try AppInspector().inspect(appAt: targetBundle)
        let launcher = root.appending(path: "launcher-binary", directoryHint: .notDirectory)
        try Data(launcherText.utf8).write(to: launcher)
        let output = root.appending(path: "out", directoryHint: .isDirectory)
        return Fixture(output: output, launcher: launcher, app: app)
    }

    private func readPlist(_ bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func entries(in directory: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testLayout() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)

        XCTAssertEqual(bundle.path, fixture.output.appending(path: "Claude Work.app", directoryHint: .isDirectory).path)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        XCTAssertTrue(fileManager.fileExists(atPath: contents.appending(path: "Info.plist").path))
        XCTAssertEqual(try Data(contentsOf: contents.appending(path: "PkgInfo")), Data("APPL????".utf8))

        let executable = contents.appending(path: "MacOS/Claude Work", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: executable), Data("launcher".utf8))
        let permissions = try fileManager.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)

        let icon = contents.appending(path: "Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([1, 2, 3]))
        XCTAssertThrowsError(try fileManager.destinationOfSymbolicLink(atPath: icon.path), "the icon must be a copy, not a symlink")
    }

    func testInfoPlistKeys() throws {
        let fixture = try makeFixture()
        let shortcut = config()
        let bundle = try BundleWriter().write(config: shortcut, app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        let plist = try readPlist(bundle)

        XCTAssertEqual(plist["CFBundleName"] as? String, "Claude Work")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Claude Work")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, shortcut.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Claude Work")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertEqual(plist["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertEqual(plist["MADEngineVersion"] as? Int, 1)
        let stored = try XCTUnwrap(plist["MADConfig"] as? [String: Any])
        XCTAssertEqual(try ShortcutConfig(plistDictionary: stored), shortcut)

        let raw = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        XCTAssertEqual(Array(raw.prefix(5)), Array("<?xml".utf8), "Info.plist must be XML format")
    }

    func testForbiddenKeysAbsent() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        let keys = try readPlist(bundle).keys

        for forbidden in BundleWriter.forbiddenInfoPlistKeys {
            XCTAssertFalse(keys.contains(forbidden), "\(forbidden) must not be written")
        }
        XCTAssertEqual(Set(BundleWriter.forbiddenInfoPlistKeys), [
            "CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
        ])
        XCTAssertFalse(keys.contains { $0.hasPrefix("UT") })
    }

    func testLSEnvironmentMergeOrder() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        let environment = try XCTUnwrap(readPlist(bundle)["LSEnvironment"] as? [String: String])
        XCTAssertEqual(environment, ["A": "target", "B": "shortcut", "C": "shortcut"])
    }

    func testNoIconOmitsIconKeys() throws {
        let fixture = try makeFixture(withIcon: false)
        XCTAssertNil(fixture.app.iconFileURL)
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)

        XCTAssertNil(try readPlist(bundle)["CFBundleIconFile"])
        XCTAssertFalse(fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
    }

    func testAtomicAndReplacing() throws {
        let fixture = try makeFixture()
        let writer = BundleWriter()
        let first = try writer.write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        XCTAssertEqual(try entries(in: fixture.output), ["Claude Work.app"])

        try Data("launcher-v2".utf8).write(to: fixture.launcher)
        let second = try writer.write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)

        XCTAssertEqual(second, first)
        let executable = second.appending(path: "Contents/MacOS/Claude Work", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: executable), Data("launcher-v2".utf8))
        XCTAssertEqual(try entries(in: fixture.output), ["Claude Work.app"])
    }

    func testSlashInNameBecomesDash() throws {
        let fixture = try makeFixture()
        let bundle = try BundleWriter().write(config: config(name: "Work/Personal"), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)

        XCTAssertEqual(bundle.lastPathComponent, "Work-Personal.app")
        XCTAssertEqual(try entries(in: fixture.output), ["Work-Personal.app"])
        XCTAssertEqual(try readPlist(bundle)["CFBundleName"] as? String, "Work/Personal")
    }

    func testExplicitIconFileWinsOverTargetIcon() throws {
        let fixture = try makeFixture(withIcon: true)
        try fileManager.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let custom = fixture.output.appending(path: "custom.icns", directoryHint: .notDirectory)
        try Data([9, 9, 9, 9]).write(to: custom)

        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, iconFile: custom, to: fixture.output)

        let icon = bundle.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([9, 9, 9, 9]))
        let info = try readPlist(bundle)
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
    }

    func testNilIconFileWritesNoIconEvenWhenTargetHasOne() throws {
        let fixture = try makeFixture(withIcon: true)

        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, iconFile: nil, to: fixture.output)

        XCTAssertFalse(fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let info = try readPlist(bundle)
        XCTAssertNil(info["CFBundleIconFile"])
    }

    func testFourArgumentWriteStillCopiesTargetIcon() throws {
        let fixture = try makeFixture(withIcon: true)
        let bundle = try BundleWriter().write(config: config(), app: fixture.app, launcherBinary: fixture.launcher, to: fixture.output)
        let icon = bundle.appending(path: "Contents/Resources/AppIcon.icns", directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: icon), Data([1, 2, 3]))
    }
}
