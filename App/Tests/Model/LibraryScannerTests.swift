import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LibraryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testScanFindsShortcutsReadsConfigIconAndTargetVersion() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "4.2.0", in: root)
        let config = makeConfig(targetPath: target.path)
        let bundle = try writeShortcutBundle(named: "Target Work", in: root, config: config)

        let result = LibraryScanner().scan(folders: [root])

        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.records.count, 1, "the fake target has no MADConfig and must not be listed")
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.bundleURL.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(record.config, config)
        XCTAssertEqual(record.engineVersion, 1)
        XCTAssertEqual(record.iconURL?.lastPathComponent, "AppIcon.icns")
        XCTAssertEqual(record.targetVersion, "4.2.0")
        XCTAssertTrue(record.targetExists)
        XCTAssertFalse(record.needsRebuild)
        XCTAssertEqual(record.name, "Target Work")
    }

    func testMissingTargetAndMissingIcon() throws {
        let config = makeConfig(targetPath: root.appending(path: "Gone.app").path)
        try writeShortcutBundle(named: "Target Work", in: root, config: config, withIcon: false)

        let record = try XCTUnwrap(LibraryScanner().scan(folders: [root]).records.first)

        XCTAssertFalse(record.targetExists)
        XCTAssertNil(record.targetVersion)
        XCTAssertNil(record.iconURL)
    }

    func testCorruptConfigBecomesWarningNotRecord() throws {
        let bundle = try writeShortcutBundle(named: "Broken", in: root, config: makeConfig(name: "Broken"))
        let info = bundle.appending(path: "Contents/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: info)?.mutableCopy() as? NSMutableDictionary)
        dict[ShortcutConfig.infoPlistKey] = ["kind": "app"]
        try dict.write(to: info)

        let result = LibraryScanner().scan(folders: [root])

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Broken.app"))
    }

    func testOlderEngineVersionNeedsRebuildAndFoldersAreDeduplicated() throws {
        try writeShortcutBundle(named: "Old", in: root, config: makeConfig(name: "Old"), engineVersion: 0)
        let missing = root.appending(path: "does-not-exist", directoryHint: .isDirectory)

        let result = LibraryScanner().scan(folders: [root, root, missing])

        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.records[0].needsRebuild)
        XCTAssertEqual(result.warnings, [], "a missing library folder is not an error")
    }

    func testRecordsSortedByNameCaseInsensitive() throws {
        try writeShortcutBundle(named: "beta", in: root, config: makeConfig(name: "beta"))
        try writeShortcutBundle(named: "Alpha", in: root, config: makeConfig(name: "Alpha"))
        XCTAssertEqual(LibraryScanner().scan(folders: [root]).records.map(\.name), ["Alpha", "beta"])
    }

    func testScanListsWebAppWithoutReadingATarget() throws {
        let config = makeWebConfig(name: "Chat Work", url: "https://chat.example.test/inbox")
        _ = try writeShortcutBundle(named: "Chat Work", in: root, config: config)

        let result = LibraryScanner().scan(folders: [root])

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(record.targetExists, "a web app has no target to be missing")
        XCTAssertNil(record.targetVersion)
        XCTAssertEqual(record.webAppHost, "chat.example.test")
        XCTAssertNil(ShortcutRecord(bundleURL: root, config: makeConfig(), engineVersion: 1, iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: .distantPast, provenance: .own).webAppHost)
    }
}
