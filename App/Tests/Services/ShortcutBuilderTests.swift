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
