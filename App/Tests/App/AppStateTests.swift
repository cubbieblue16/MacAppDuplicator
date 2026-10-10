import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppStateTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var target: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var library: ShortcutLibrary!
    private var state: AppState!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        (defaults, suite) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        library = ShortcutLibrary(settings: settings)
        let launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        state = AppState(settings: settings, library: library, launcherBinary: launcher)
    }

    override func tearDown() async throws {
        library.stop()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: dir)
    }

    private func config(name: String = "Target Work") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target.path)
        c.iconMode = .generated
        return c
    }

    func testCreateSelectsNewRecordAndRescans() async throws {
        let url = await state.create(config: config())
        XCTAssertNotNil(url)
        XCTAssertEqual(state.selection, url)
        XCTAssertEqual(library.records.map(\.name), ["Target Work"])
        // The selection is the sidebar row's tag (the scanned URL), even when the temp path runs through /var -> /private/var.
        XCTAssertEqual(state.selection, library.records.first?.bundleURL)
        XCTAssertNil(state.pendingError)
    }

    func testCreateDuplicateNameReportsError() async throws {
        _ = await state.create(config: config())
        let second = await state.create(config: config())
        XCTAssertNil(second)
        XCTAssertEqual(state.pendingError?.context, "Could not create shortcut")
    }

    func testSaveRewritesAndKeepsSelection() async throws {
        let created = await state.create(config: config())
        let url = try XCTUnwrap(created)
        let record = try XCTUnwrap(library.record(for: url))
        var updated = record.config
        updated.arguments = ["--a"]
        let ok = await state.save(record: record, config: updated)
        XCTAssertTrue(ok)
        XCTAssertEqual(library.record(for: url)?.config.arguments, ["--a"])
        XCTAssertEqual(state.selection, url)
    }

    func testSaveWithRenameMovesSelection() async throws {
        let created = await state.create(config: config())
        let url = try XCTUnwrap(created)
        let record = try XCTUnwrap(library.record(for: url))
        var updated = record.config
        updated.name = "Target Personal"
        updated.slug = ShortcutConfig.slug(for: updated.name)
        updated.bundleIdentifier = ShortcutConfig.bundleIdentifier(forSlug: updated.slug)
        let saved = await state.save(record: record, config: updated)
        XCTAssertTrue(saved)
        XCTAssertEqual(library.records.map(\.name), ["Target Personal"])
        XCTAssertEqual(state.selection?.lastPathComponent, "Target Personal.app")
    }

    func testDuplicateExportDeleteRoundTrip() async throws {
        let created = await state.create(config: config())
        let url = try XCTUnwrap(created)
        let record = try XCTUnwrap(library.record(for: url))
        await state.duplicate(record, newName: "Target Two")
        XCTAssertEqual(library.records.map(\.name), ["Target Two", "Target Work"])

        let exported = dir.appending(path: "Exported.app")
        let didExport = await state.export(record, to: exported)
        XCTAssertTrue(didExport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))

        let trashed = await state.delete(record, removeData: false)
        addTeardownBlock { for url in trashed { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(library.records.map(\.name), ["Target Two"])
        XCTAssertNil(state.selection)
    }

    func testDeleteRefusesADataFolderSharedWithAnotherShortcutAndKeepsBoth() async throws {
        let shared = dir.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        var first = config(name: "First")
        first.dataMode = .homeOverride
        first.dataPath = shared.path
        var second = config(name: "Second")
        second.dataMode = .homeOverride
        second.dataPath = shared.path
        let created = await state.create(config: first)
        _ = await state.create(config: second)
        let record = try XCTUnwrap(library.record(for: try XCTUnwrap(created)))

        let trashed = await state.delete(record, removeData: true)

        XCTAssertEqual(trashed, [])
        XCTAssertEqual(state.pendingError?.context, "Could not delete shortcut")
        XCTAssertEqual(library.records.map(\.name), ["First", "Second"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        guard case .unavailable = state.dataFolderDeletionOption(for: record) else { return XCTFail("a shared data folder must not be offered") }
    }

    func testDataFolderDeletionIsOfferedOnlyForAnExistingSafeFolder() async throws {
        let existing = dir.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        func record(_ name: String, mode: DataMode, path: URL?) async throws -> ShortcutRecord {
            var c = config(name: name)
            c.dataMode = mode
            c.dataPath = path?.path
            let created = await state.create(config: c)
            return try XCTUnwrap(library.record(for: try XCTUnwrap(created)))
        }

        let disabled = try await record("Disabled", mode: .disabled, path: nil)
        let missing = try await record("Missing", mode: .homeOverride, path: dir.appending(path: "missing"))
        let unsafe = try await record("Unsafe", mode: .homeOverride, path: out)
        let safe = try await record("Safe", mode: .homeOverride, path: existing)

        guard case .unavailable = state.dataFolderDeletionOption(for: disabled) else { return XCTFail("Disabled mode has no data folder to trash") }
        guard case .unavailable = state.dataFolderDeletionOption(for: missing) else { return XCTFail("a missing folder is not offered") }
        guard case .unavailable(let note) = state.dataFolderDeletionOption(for: unsafe) else { return XCTFail("the output folder is refused") }
        XCTAssertTrue(note.contains("library folder"), note)
        guard case .available(let folder, let outsideDataRoot) = state.dataFolderDeletionOption(for: safe) else { return XCTFail("a safe folder is offered") }
        XCTAssertEqual(folder.lastPathComponent, "data")
        XCTAssertTrue(outsideDataRoot, "a temp folder is outside ~/Library/Application Support/App Duplicator")
    }

    func testRebuildAllRewritesOnlyStaleRecords() async throws {
        _ = await state.create(config: config())
        // A real stale shortcut carries the old engine version in its MADConfig as well as in MADEngineVersion.
        var old = config(name: "Old One")
        old.engineVersion = 0
        try writeShortcutBundle(named: "Old One", in: out, config: old, engineVersion: 0)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["Old One"])
        let count = await state.rebuildAll()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(library.recordsNeedingRebuild.isEmpty)
    }
}
