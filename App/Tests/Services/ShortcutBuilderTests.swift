import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ShortcutBuilderTests: XCTestCase {
    private var dir: URL!
    private var target: URL!
    private var launcher: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        // The fake target needs a real Mach-O executable for AppInspector; /bin/ls is a universal binary. Copy, don't link.
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        builder = ShortcutBuilder(launcherBinary: launcher, signingIdentity: nil)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func config(name: String = "Target Work") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target.path)
        c.iconMode = .generated
        return c
    }

    func testCreateWritesSignedBundleWithIconAndRefusesDuplicate() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)

        XCTAssertEqual(bundle.lastPathComponent, "Target Work.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.iconMode, .generated)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardError = Pipe()
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)

        XCTAssertThrowsError(try builder.create(config: config(), in: out)) { error in
            guard case ShortcutBuilder.BuilderError.alreadyExists = error else { return XCTFail("\(error)") }
        }
    }

    func testCreateWithMissingTargetThrows() {
        var c = config()
        c.targetPath = dir.appending(path: "Gone.app").path
        XCTAssertThrowsError(try builder.create(config: c, in: dir)) { error in
            guard case ShortcutBuilder.BuilderError.targetMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testRegenerateRewritesInPlaceAndKeepsPath() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        var record = try LibraryScanner.record(forBundleAt: bundle)
        var updated = record.config
        updated.arguments = ["--flag"]
        let rewritten = try builder.regenerate(record: record, config: updated)
        XCTAssertEqual(rewritten, bundle)
        record = try LibraryScanner.record(forBundleAt: rewritten)
        XCTAssertEqual(record.config.arguments, ["--flag"])
    }

    func testRegenerateStampsCurrentEngineVersion() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var stale = config()
        stale.engineVersion = 0
        let bundle = try writeShortcutBundle(named: "Target Work", in: out, config: stale, engineVersion: 0)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.engineVersion, 0)

        let rewritten = try builder.regenerate(record: record, config: record.config)

        let data = try Data(contentsOf: rewritten.appending(path: "Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info[ShortcutConfig.engineVersionInfoPlistKey] as? Int, ShortcutConfig.currentEngineVersion)
        let rawConfig = try XCTUnwrap(info[ShortcutConfig.infoPlistKey] as? [String: Any])
        XCTAssertEqual(try ShortcutConfig(plistDictionary: rawConfig).engineVersion, ShortcutConfig.currentEngineVersion)
    }

    func testDuplicateCreatesSecondBundleWithNewIdentity() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let first = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: first)
        let second = try builder.duplicate(record: record, newName: "Target Personal", in: out)
        let copy = try LibraryScanner.record(forBundleAt: second)
        XCTAssertEqual(second.lastPathComponent, "Target Personal.app")
        XCTAssertEqual(copy.config.slug, ShortcutConfig.slug(for: "Target Personal"))
        XCTAssertEqual(copy.config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: copy.config.slug))
        XCTAssertEqual(copy.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: copy.config.slug, home: FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertNotEqual(copy.config.dataPath, record.config.dataPath, "a duplicate gets its own default data folder, not the original's")
        XCTAssertEqual(copy.config.targetPath, record.config.targetPath)
    }

    func testCreateResolvesDefaultDataPathWhenNil() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .auto
        c.dataPath = nil
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: c.slug, home: FileManager.default.homeDirectoryForCurrentUser))
    }

    func testCreateKeepsNilDataPathWhenDataModeDisabled() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .disabled
        c.dataPath = nil
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertNil(record.config.dataPath)
    }

    func testExportCopiesBundle() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exported = try builder.export(record: record, to: dir.appending(path: "exported.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testExportRefusesTheShortcutItselfAndPathsInsideOrAroundIt() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        for destination in [bundle, bundle.appending(path: "Contents/Nested.app"), out] {
            XCTAssertThrowsError(try builder.export(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path), "self-export must leave the shortcut intact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"], "no staging copy left behind")
    }

    func testExportRefusesTheTargetAndPathsInsideOrAroundIt() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let targetExecutable = try Data(contentsOf: target.appending(path: "Contents/MacOS/Target"))
        for destination in [target!, target.appending(path: "Contents/Inner.app"), dir!] {
            XCTAssertThrowsError(try builder.export(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsTarget = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: target.appending(path: "Contents/MacOS/Target")), targetExecutable, "the target is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appending(path: "Contents/Info.plist").path))
    }

    func testExportReplacesAnExistingDestination() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        let destination = exportDir.appending(path: "Exported.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))

        let exported = try builder.export(record: record, to: destination)

        XCTAssertEqual(exported.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "old-marker").path))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")), try Data(contentsOf: bundle.appending(path: "Contents/Info.plist")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
    }

    func testFailedExportKeepsTheSourceAndAnyExistingDestination() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        // The destination folder does not exist, so the staging copy fails before anything is moved.
        XCTAssertThrowsError(try builder.export(record: record, to: dir.appending(path: "missing/Exported.app")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))

        // The source is gone, so the copy fails; the existing destination must survive untouched.
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        let destination = exportDir.appending(path: "Exported.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))
        try FileManager.default.moveItem(at: bundle, to: dir.appending(path: "moved-away.app"))
        XCTAssertThrowsError(try builder.export(record: record, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "old-marker")), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
    }

    func testDeleteRefusesAnUnsafeDataFolderBeforeTrashingAnything() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .homeOverride
        c.dataPath = out.path
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        XCTAssertThrowsError(try builder.delete(record: record, removeData: true)) { error in
            guard case DataPathGuardError.overlapsLibraryFolder = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "a refused delete must not trash the bundle either")

        let shared = dir.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        c.dataPath = shared.path
        let rewritten = try builder.regenerate(record: record, config: c)
        XCTAssertThrowsError(try builder.delete(record: try LibraryScanner.record(forBundleAt: rewritten), removeData: true, otherRecordDataPaths: [shared.path])) { error in
            guard case DataPathGuardError.usedByAnotherShortcut = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rewritten.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testDeleteRemovesBundleAndOptionallyDataFolder() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        let data = dir.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        c.dataMode = .homeOverride
        c.dataPath = data.path
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        let trashedBundle = try builder.delete(record: record, removeData: false)
        addTeardownBlock { for url in trashedBundle { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedBundle.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))

        let again = try builder.create(config: c, in: out)
        let trashedBoth = try builder.delete(record: try LibraryScanner.record(forBundleAt: again), removeData: true)
        addTeardownBlock { for url in trashedBoth { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedBoth.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }
}
