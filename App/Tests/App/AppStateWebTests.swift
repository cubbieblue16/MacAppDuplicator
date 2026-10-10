import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

@MainActor
final class AppStateWebTests: XCTestCase {
    private var dir: URL!
    private var out: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var running: RunningPaths!
    private var library: ShortcutLibrary!
    private var remover: FakeWebDataRemover!
    private var state: AppState!
    private var launcher: URL!
    private var webShell: URL!

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        out = dir.appending(path: "out", directoryHint: .isDirectory)
        (defaults, suite) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        running = RunningPaths()
        let runningPaths = running!
        library = ShortcutLibrary(settings: settings, monitor: RunningShortcutMonitor(probe: { runningPaths.paths }))
        launcher = dir.appending(path: "Launcher")
        webShell = dir.appending(path: "WebShell")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: webShell)
        useRemover(FakeWebDataRemover())
    }

    override func tearDown() async throws {
        library.stop()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: dir)
    }

    private func useRemover(_ newRemover: FakeWebDataRemover) {
        remover = newRemover
        state = makeWebTestAppState(settings: settings, library: library, launcher: launcher, webShell: webShell, remover: newRemover)
    }

    /// Writes a web-app bundle into the output folder, rescans and returns its record.
    private func makeWebRecord(name: String = "Chat", dataStoreID: UUID = UUID()) async throws -> ShortcutRecord {
        let bundle = try writeShortcutBundle(named: name, in: out, config: makeWebShortcutConfig(name: name, dataStoreID: dataStoreID))
        await library.rescan()
        return try XCTUnwrap(library.record(for: bundle))
    }

    func testRemoveWebDataPassesTheStoreIdAndTheShortcutBundleIdentifier() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)

        let removed = await state.removeWebData(for: record)

        XCTAssertTrue(removed)
        XCTAssertEqual(remover.calls, [FakeWebDataRemover.Call(identifier: id, bundleIdentifier: "com.mikekuta.appduplicator.chat")])
        XCTAssertNil(state.pendingError)
    }

    func testRemoveWebDataFailureSurfacesAnAlert() async throws {
        useRemover(FakeWebDataRemover(failureMessage: "The disk is on fire."))
        let record = try await makeWebRecord()

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertEqual(state.pendingError?.context, "Could not remove web data")
        XCTAssertEqual(state.pendingError?.message, "The disk is on fire.")
    }

    func testRemoveWebDataIsRefusedWhileTheWebAppRuns() async throws {
        let record = try await makeWebRecord()
        running.set([record.bundleURL.standardizedFileURL.path])
        await library.monitor.refresh()

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertTrue(remover.calls.isEmpty, "a running web app keeps its store open, so nothing is removed")
        XCTAssertEqual(state.pendingError?.message, "Quit “Chat” before removing its web data.")
    }

    func testRemoveWebDataIgnoresAShortcutThatIsNotAWebApp() async throws {
        let bundle = try writeShortcutBundle(named: "Plain", in: out, config: makeConfig(name: "Plain"))
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))

        let removed = await state.removeWebData(for: record)

        XCTAssertFalse(removed)
        XCTAssertTrue(remover.calls.isEmpty)
        XCTAssertNil(state.pendingError)
    }

    func testDeleteKeepsWebDataByDefault() async throws {
        let record = try await makeWebRecord()

        let trashed = await state.delete(record, removeData: false)

        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(remover.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path))
    }

    func testDeleteRemovesWebDataBeforeTrashingWhenAsked() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)

        let trashed = await state.delete(record, removeData: false, removeWebData: true)

        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(remover.calls.map(\.identifier), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path))
        XCTAssertNil(state.pendingError)
    }

    func testDeleteStopsAndKeepsTheShortcutWhenWebDataRemovalFails() async throws {
        useRemover(FakeWebDataRemover(failureMessage: "Permission denied."))
        let record = try await makeWebRecord()

        let trashed = await state.delete(record, removeData: false, removeWebData: true)

        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.bundleURL.path), "the shortcut stays so the user can retry")
        XCTAssertEqual(state.pendingError?.context, "Could not remove web data")
    }

    func testDataFolderDeletionIsUnavailableForAWebApp() async throws {
        let record = try await makeWebRecord()
        XCTAssertEqual(
            state.dataFolderDeletionOption(for: record),
            .unavailable(note: "A web app keeps its logins and cookies in web data, not in a data folder.")
        )
    }

    // MARK: Editor Save (coordinator constraint: Save passes no icon data, the fetched icon stays)

    private var iconBytes: Data { Data([1, 2, 3]) }

    private func iconFile(in bundle: URL) -> URL { bundle.appending(path: "Contents/Resources/AppIcon.icns") }

    /// What `ShortcutEditorView.save()` hands `AppState.save` for a web app after the draft is edited.
    private func editorSaveConfig(of record: ShortcutRecord, _ edit: (inout ShortcutConfig) -> Void) -> ShortcutConfig {
        var draft = record.config
        edit(&draft)
        return WebEditorPolicy.saveConfig(draft: draft, saved: record.config)
    }

    func testEditorSaveKeepsTheFetchedIconBytes() async throws {
        let record = try await makeWebRecord()
        XCTAssertEqual(record.config.iconMode, .copied)
        XCTAssertEqual(try Data(contentsOf: iconFile(in: record.bundleURL)), iconBytes, "precondition: the bundle holds the fetched icon")
        let config = editorSaveConfig(of: record) {
            $0.webApp?.userAgent = .chrome
            $0.webApp?.extraHosts = ["login.example.com"]
        }

        let saved = await state.save(record: record, config: config)

        XCTAssertTrue(saved, state.pendingError?.message ?? "")
        let after = try XCTUnwrap(library.record(for: record.bundleURL))
        XCTAssertEqual(after.config.webApp?.userAgent, .chrome)
        XCTAssertEqual(after.config.webApp?.extraHosts, ["login.example.com"])
        XCTAssertEqual(after.config.iconMode, .copied)
        XCTAssertEqual(try Data(contentsOf: iconFile(in: after.bundleURL)), iconBytes, "Save without new icon data must keep AppIcon.icns byte for byte")
    }

    func testEditorRenameKeepsTheBundleIdentifierTheStoreAndTheIconBytes() async throws {
        let id = UUID()
        let record = try await makeWebRecord(dataStoreID: id)
        let config = editorSaveConfig(of: record) { $0.name = "  Chat Work " }

        let saved = await state.save(record: record, config: config)

        XCTAssertTrue(saved, state.pendingError?.message ?? "")
        let renamedBundle = out.appending(path: "Chat Work.app", directoryHint: .isDirectory)
        let after = try XCTUnwrap(library.record(for: renamedBundle))
        XCTAssertEqual(after.config.name, "Chat Work")
        XCTAssertEqual(after.config.slug, "chat")
        XCTAssertEqual(after.config.bundleIdentifier, "com.mikekuta.appduplicator.chat", "the bundle id keys WebKit's store, so a rename must keep it")
        XCTAssertEqual(after.config.webApp?.dataStoreID, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path), "the old bundle is replaced")
        XCTAssertEqual(try Data(contentsOf: iconFile(in: renamedBundle)), iconBytes)
    }

    func testEditorSaveNeverTouchesWebData() async throws {
        let record = try await makeWebRecord()
        let config = editorSaveConfig(of: record) { $0.webApp?.userAgent = .chrome }

        _ = await state.save(record: record, config: config)

        XCTAssertTrue(remover.calls.isEmpty, "Save keeps the logins; only Remove Web Data and Delete remove them")
    }
}
