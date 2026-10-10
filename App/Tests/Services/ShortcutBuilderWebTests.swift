import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Web apps have no target app: export and delete must work from the bundle alone (coordinator item from Task 4).
final class ShortcutBuilderWebTests: XCTestCase {
    private var dir: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        let launcher = dir.appending(path: "Launcher")
        let webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: webShell)
        builder = ShortcutBuilder(launcherBinary: launcher, webShellBinary: webShell, signingIdentity: nil)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// A scanned web-app record whose bundle sits in `folder` (Task 4 assumption A3: the scanner accepts it).
    private func webRecord(name: String = "Chat", in folder: URL, targetBundleIdentifier: String = "") throws -> ShortcutRecord {
        var config = makeWebShortcutConfig(name: name)
        config.targetBundleIdentifier = targetBundleIdentifier
        let bundle = try writeShortcutBundle(named: name, in: folder, config: config)
        return try LibraryScanner.record(forBundleAt: bundle)
    }

    func testResolvedPathIsNilForAWebAppEvenWithAStrayBundleIdentifier() {
        var web = makeWebShortcutConfig()
        XCTAssertNil(TargetResolver().resolvedPath(for: web))
        // A hand-edited plist could leave a bundle id behind; Finder is installed on every Mac, so a Launch Services
        // lookup would find it. A web app has no target to find.
        web.targetBundleIdentifier = "com.apple.finder"
        XCTAssertNil(TargetResolver().resolvedPath(for: web))

        var app = makeConfig(name: "Finder Copy", targetPath: "/nonexistent/Finder.app")
        app.targetBundleIdentifier = "com.apple.finder"
        XCTAssertNotNil(TargetResolver().resolvedPath(for: app), "app shortcuts keep resolving through Launch Services")
    }

    func testExportCopiesAWebBundleWithoutATarget() throws {
        let record = try webRecord(in: dir)
        let destination = dir.appending(path: "Chat Export.app")

        let exported = try builder.export(record: record, to: destination, otherTargetPaths: ["", "/Applications/Other.app"])

        XCTAssertEqual(exported, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.bundleURL.path), "export copies; the original stays")
    }

    func testExportOfAWebBundleStillRefusesItsOwnBundle() throws {
        let record = try webRecord(in: dir)
        XCTAssertThrowsError(try builder.export(record: record, to: record.bundleURL.appending(path: "Contents/Inner.app"))) { error in
            guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(error)") }
        }
    }

    func testDeleteTrashesAWebBundleWhetherOrNotDataRemovalIsAsked() throws {
        let keep = try webRecord(name: "Chat Keep", in: dir)
        let trashedKeep = try builder.delete(record: keep, removeData: false)
        addTeardownBlock { for url in trashedKeep { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedKeep.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keep.bundleURL.path))

        // A web app has no data folder (dataMode .disabled, dataPath nil): asking for it trashes the bundle only and the
        // data-path guard is never consulted, so no target lookup happens either.
        let remove = try webRecord(name: "Chat Remove", in: dir)
        let trashedRemove = try builder.delete(record: remove, removeData: true)
        addTeardownBlock { for url in trashedRemove { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedRemove.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remove.bundleURL.path))
    }
}
