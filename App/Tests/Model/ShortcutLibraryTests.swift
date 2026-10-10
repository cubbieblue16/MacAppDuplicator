import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class ShortcutLibraryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    // Async overrides run on the main actor, so they can touch the class's main-actor state (final review M19).
    override func setUp() async throws {
        root = try makeAppTemporaryDirectory()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDown() async throws {
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

    func testStartAgainReplacesTheWatcherAndFollowsTheFolderList() async throws {
        let extra = try makeAppTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: extra) }
        try writeShortcutBundle(named: "Extra", in: extra, config: makeConfig(name: "Extra"))
        let library = makeLibrary()
        defer { library.stop() }

        library.start()
        let first = try XCTUnwrap(library.watcher)
        library.start()
        let second = try XCTUnwrap(library.watcher)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.watchedSourceCount, 0, "the previous watcher's sources are cancelled")
        XCTAssertEqual(second.watchedSourceCount, 1, "an unchanged folder is watched once, not twice")

        library.settings.libraryFolders = [extra]
        library.start()
        let third = try XCTUnwrap(library.watcher)
        XCTAssertEqual(second.watchedSourceCount, 0)
        XCTAssertEqual(third.watchedSourceCount, 2, "an added folder is watched")
        await waitUntil { library.records.map(\.name) == ["Extra"] }
        XCTAssertEqual(library.records.map(\.name), ["Extra"], "start() rescans the new folder list")

        library.settings.libraryFolders = []
        library.start()
        XCTAssertEqual(third.watchedSourceCount, 0)
        XCTAssertEqual(library.watcher?.watchedSourceCount, 1, "a removed folder is no longer watched")
    }
}
