import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class TargetGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testABundleCarryingMADConfigIsRefused() throws {
        let shortcut = try writeShortcutBundle(named: "Claude Work", in: dir, config: makeConfig(name: "Claude Work"))
        XCTAssertTrue(TargetGuard.isShortcutBundle(at: shortcut))
    }

    func testAPlainAppIsAccepted() throws {
        let app = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: app))
    }

    func testABundleWithoutInfoPlistIsNotAShortcut() throws {
        let bare = dir.appending(path: "Bare.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: dir.appending(path: "Bare.app", directoryHint: .isDirectory)))
        XCTAssertFalse(TargetGuard.isShortcutBundle(at: dir.appending(path: "Missing.app", directoryHint: .isDirectory)))
    }

    func testRefusalMessageNamesTheBundle() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/Claude Work.app")
        XCTAssertEqual(
            TargetGuard.refusalMessage(forAppAt: url),
            "Claude Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
    }
}
