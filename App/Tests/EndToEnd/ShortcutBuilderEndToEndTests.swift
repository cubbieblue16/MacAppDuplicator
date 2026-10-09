import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Builds a real shortcut for the FixtureApp with the embedded Launcher, then verifies the bundle the way
/// Finder, codesign and the library scanner would. Skips when the fixture has not been built.
final class ShortcutBuilderEndToEndTests: XCTestCase {
    private var dir: URL!
    private var fixture: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        fixture = repoRoot.appending(path: ".build/fixtures/FixtureApp.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.appending(path: "Contents/MacOS/FixtureApp").path),
                          "FixtureApp missing; run Tools/build-fixture.sh")
        dir = try makeAppTemporaryDirectory()
        builder = ShortcutBuilder(launcherBinary: try EmbeddedLauncher.url(), signingIdentity: nil)
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    private func config(name: String) -> ShortcutConfig {
        makeConfig(name: name, targetPath: fixture.path, targetBundleIdentifier: "com.mikekuta.appduplicator.fixture")
    }

    private func codesignVerify(_ bundle: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testCreateProducesLaunchableSignedBundle() throws {
        let bundle = try builder.create(config: config(name: "Fixture Work"), in: dir)
        XCTAssertEqual(bundle.lastPathComponent, "Fixture Work.app")

        let contents = bundle.appending(path: "Contents")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: contents.appending(path: "MacOS/Fixture Work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appending(path: "Resources/AppIcon.icns").path))

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: contents.appending(path: "Info.plist")), format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, ShortcutConfig.bundleIdentifier(forSlug: ShortcutConfig.slug(for: "Fixture Work")))
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist[ShortcutConfig.engineVersionInfoPlistKey] as? Int, ShortcutConfig.currentEngineVersion)
        XCTAssertNotNil(plist[ShortcutConfig.infoPlistKey])

        XCTAssertEqual(try codesignVerify(bundle), 0, "codesign --verify --deep --strict failed")

        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        XCTAssertEqual(record.name, "Fixture Work")
        XCTAssertEqual(record.targetVersion, "1.0")
        XCTAssertTrue(record.targetExists)
        XCTAssertFalse(record.needsRebuild)
        XCTAssertNotNil(record.iconURL)

        let preview = try LaunchPlanPreview.make(config: record.config, bundleURL: bundle)
        XCTAssertEqual(preview.executablePath, fixture.appending(path: "Contents/MacOS/FixtureApp").path)
        XCTAssertEqual(preview.launchMode, .dockShortcut)
        XCTAssertTrue(preview.environmentAdditions.keys.contains("HOME"), "native fixture should get a HOME override")
        // The fixture is a native app outside the verified families, so the planner always reports this one warning.
        XCTAssertEqual(preview.warnings, ["untested app; HOME override applied"])
    }

    func testLifecycleRegenerateDuplicateExportDelete() throws {
        let bundle = try builder.create(config: config(name: "Fixture A"), in: dir)
        var record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        var changed = record.config
        changed.appearance = .light
        let regenerated = try builder.regenerate(record: record, config: changed)
        XCTAssertEqual(regenerated, bundle)
        record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        XCTAssertEqual(record.config.appearance, .light)
        XCTAssertEqual(try codesignVerify(bundle), 0)

        let copy = try builder.duplicate(record: record, newName: "Fixture B", in: dir)
        XCTAssertEqual(copy.lastPathComponent, "Fixture B.app")
        let copyRecord = try XCTUnwrap(LibraryScanner.record(forBundleAt: copy, fileManager: .default))
        XCTAssertEqual(copyRecord.config.slug, ShortcutConfig.slug(for: "Fixture B"))
        XCTAssertNotEqual(copyRecord.config.bundleIdentifier, record.config.bundleIdentifier)
        XCTAssertEqual(try codesignVerify(copy), 0)

        let exportDir = dir.appending(path: "export")
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let exported = try builder.export(record: copyRecord, to: exportDir.appending(path: "Fixture B.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "Contents/Info.plist").path))

        try builder.delete(record: copyRecord, removeData: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }
}
