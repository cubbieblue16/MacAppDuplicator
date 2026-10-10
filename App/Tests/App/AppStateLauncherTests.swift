import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// The delete sheet's data-folder option for command shortcuts (Phase 5 Task 6 fix): a command's own HOME is offered for
/// the Trash only when it sits inside App Duplicator's data root and passes `DataPathGuard`.
@MainActor
final class AppStateLauncherTests: XCTestCase {
    private var dir: URL!
    private var home: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var library: ShortcutLibrary!
    private var state: AppState!
    private var executable: URL!
    /// Trash locations returned by `delete`, removed in tearDown.
    private var trashed: [URL] = []

    override func setUp() async throws {
        dir = try makeAppTemporaryDirectory()
        home = dir.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        executable = dir.appending(path: "tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        (defaults, suite) = makeTestDefaults()
        settings = AppSettings(defaults: defaults, defaultSigningIdentity: AppSettings.adHocIdentityName)
        settings.outputFolder = out
        library = ShortcutLibrary(settings: settings)
        let launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        state = AppState(settings: settings, library: library, launcherBinary: launcher, home: home)
    }

    override func tearDown() async throws {
        library.stop()
        defaults.removePersistentDomain(forName: suite)
        for url in trashed {
            do { try FileManager.default.removeItem(at: url) } catch { /* fixture already gone */ }
        }
        try FileManager.default.removeItem(at: dir)
    }

    private func commandConfig(name: String = "Tool Home", slug: String? = nil, homeOverride: Bool) -> ShortcutConfig {
        var config = makeConfig(name: name, targetPath: "", targetBundleIdentifier: "", kind: .cli)
        if let slug { config.slug = slug }
        config.dataMode = .disabled
        config.cli = CLIConfig(executablePath: executable.path, homeOverride: homeOverride)
        return config
    }

    /// Writes the bundle into the output folder, rescans, and returns the scanned record.
    private func scannedRecord(for config: ShortcutConfig) async throws -> ShortcutRecord {
        try FileManager.default.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
        let bundle = try writeShortcutBundle(named: config.name, in: settings.outputFolder, config: config)
        await library.rescan()
        return try XCTUnwrap(library.record(for: bundle))
    }

    private func samePath(_ a: URL, _ b: String) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func testCommandHomeInsideDataRootIsOffered() async throws {
        let config = commandConfig(homeOverride: true)
        let record = try await scannedRecord(for: config)
        let path = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        guard case .available(let folder, let outsideDataRoot) = state.dataFolderDeletionOption(for: record) else {
            return XCTFail("expected the command's HOME to be offered")
        }
        XCTAssertFalse(outsideDataRoot)
        XCTAssertTrue(samePath(folder, path), "\(folder.path) vs \(path)")
    }

    func testCommandWithoutOwnHomeHasNoDataFolder() async throws {
        let record = try await scannedRecord(for: commandConfig(homeOverride: false))
        guard case .unavailable(let note) = state.dataFolderDeletionOption(for: record) else {
            return XCTFail("expected no data folder")
        }
        XCTAssertTrue(note.contains("uses your HOME"), note)
    }

    func testCommandHomeMissingOnDiskIsNotOffered() async throws {
        let record = try await scannedRecord(for: commandConfig(homeOverride: true))
        guard case .unavailable = state.dataFolderDeletionOption(for: record) else {
            return XCTFail("a missing HOME folder must not be offered")
        }
    }

    func testCommandHomeSlugEscapeIsRefused() async throws {
        // dataRoot/../../escape resolves to <home>/Library/escape, outside App Duplicator's data folder.
        let config = commandConfig(name: "Escape Tool", slug: "../../escape", homeOverride: true)
        let record = try await scannedRecord(for: config)
        XCTAssertEqual(record.config.slug, "../../escape")
        // The data root must exist, or the kernel cannot resolve the `..` hops and the folder reads as missing.
        try FileManager.default.createDirectory(at: ShortcutConfig.dataRoot(home: home), withIntermediateDirectories: true)
        let escaped = home.appending(path: "Library/escape", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)

        guard case .unavailable(let note) = state.dataFolderDeletionOption(for: record) else {
            return XCTFail("a slug that escapes the data root must not be offered")
        }
        XCTAssertTrue(note.contains("outside App Duplicator's data folder"), note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testDeleteWithRemoveDataTrashesBundleAndOwnHomeOnly() async throws {
        let config = commandConfig(homeOverride: true)
        let record = try await scannedRecord(for: config)
        let path = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        let result = await state.delete(record, removeData: true, removeWebData: false)
        trashed = result
        XCTAssertNil(state.pendingError)
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.bundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ShortcutConfig.dataRoot(home: home).path))
    }
}
