import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class ShortcutLibraryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = try makeAppTemporaryDirectory()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func makeLibrary() -> ShortcutLibrary {
        let settings = AppSettings(defaults: defaults, defaultSigningIdentity: "Ad-hoc")
        settings.outputFolder = root
        return ShortcutLibrary(settings: settings, monitor: RunningShortcutMonitor())
    }

    func testRescanPopulatesRecordsAndLookups() async throws {
        try writeShortcutBundle(named: "Target Work", in: root, config: makeConfig())
        try writeShortcutBundle(named: "Old", in: root, config: makeConfig(name: "Old"), engineVersion: 0)
        let library = makeLibrary()

        await library.rescan()

        XCTAssertEqual(library.records.map(\.name), ["Old", "Target Work"])
        XCTAssertEqual(library.records(ofKind: .app).count, 2)
        XCTAssertEqual(library.records(ofKind: .webApp).count, 0)
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["Old"])
        XCTAssertNotNil(library.record(for: root.appending(path: "Old.app")))
        XCTAssertFalse(library.isRunning(library.records[0]))
        XCTAssertFalse(library.isScanning)
    }

    func testStartWatchesFolderAndPicksUpNewBundle() async throws {
        let library = makeLibrary()
        library.start()
        defer { library.stop() }
        await waitUntil { library.records.isEmpty && !library.isScanning }

        try writeShortcutBundle(named: "Late", in: root, config: makeConfig(name: "Late"))

        await waitUntil { library.records.map(\.name) == ["Late"] }
        XCTAssertEqual(library.records.map(\.name), ["Late"])
    }
}
