import CompatProfiles
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

    func testCreateStampsACustomizedHomeSymlinkList() async throws {
        let defaultCreated = await state.create(config: config(name: "Default List"))
        settings.homeSymlinkEntries = [".ssh", ".aws"]
        let customCreated = await state.create(config: config(name: "Custom List"))

        let defaultRecord = try XCTUnwrap(library.record(for: try XCTUnwrap(defaultCreated)))
        let customRecord = try XCTUnwrap(library.record(for: try XCTUnwrap(customCreated)))
        XCTAssertNil(defaultRecord.config.homeSymlinkEntries, "the default list is left out, so the launcher keeps the built-in default")
        XCTAssertEqual(customRecord.config.homeSymlinkEntries, [".ssh", ".aws"])
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
        let results = await state.rebuildAll()
        XCTAssertEqual(results.map(\.name), ["Old One"])
        XCTAssertEqual(results.map(\.outcome), [.rebuilt])
        XCTAssertTrue(library.recordsNeedingRebuild.isEmpty)
    }

    func testCheckProfileUpdatesUsesTheSettingsURLAndReportsTheResult() async throws {
        let fork = "https://raw.githubusercontent.com/example/fork/main/profiles.json"
        settings.profilesURLString = fork
        let fetcher = StubProfilesFetcher(.success(try makeProfilesJSON(updated: "2026-10-11", apps: ["com.example.target": "verified"])))
        let profiles = ProfilesModel(bundledURL: nil, cacheURL: dir.appending(path: "profiles.json", directoryHint: .notDirectory), fetcher: fetcher)
        let checking = AppState(settings: settings, library: library, launcherBinary: dir.appending(path: "Launcher"), profiles: profiles)
        XCTAssertNil(state.profile(forBundleIdentifier: "com.example.target"), "the default model is inert and empty")

        let message = await checking.checkProfileUpdates()

        XCTAssertEqual(message, "Downloaded profiles from 2026-10-11.")
        XCTAssertEqual(checking.profileUpdateMessage, message)
        XCTAssertEqual(fetcher.requestedURLs.map(\.absoluteString), [fork])
        XCTAssertEqual(checking.profile(forBundleIdentifier: "com.example.target")?.status, .verified)
    }

    func testRebuildAllContinuesPastAFailureAndReportsEveryShortcut() async throws {
        // "A Broken" sorts first and its target is gone; Phase 2's loop stopped there and never reached "B Stale".
        var broken = config(name: "A Broken")
        broken.targetPath = dir.appending(path: "Missing.app").path
        broken.engineVersion = 0
        try writeShortcutBundle(named: "A Broken", in: out, config: broken, engineVersion: 0)
        var stale = config(name: "B Stale")
        stale.engineVersion = 0
        try writeShortcutBundle(named: "B Stale", in: out, config: stale, engineVersion: 0)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["A Broken", "B Stale"])

        let results = await state.rebuildAll()

        XCTAssertEqual(results.map(\.name), ["A Broken", "B Stale"])
        XCTAssertEqual(results.map(\.id.lastPathComponent), ["A Broken.app", "B Stale.app"])
        XCTAssertEqual(results.last?.outcome, .rebuilt)
        guard case .failed(let message) = results.first?.outcome else { return XCTFail("the missing target fails") }
        XCTAssertTrue(message.contains("Missing.app"), message)
        XCTAssertNil(state.pendingError, "Rebuild All reports failures in its results, not in the error alert")
        XCTAssertNil(state.rebuildProgress, "progress is cleared when Rebuild All ends")
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["A Broken"])
    }
}
