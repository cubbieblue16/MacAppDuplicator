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

    /// Marks a fixture bundle as written by this install (C3); pair it with `adHocSignFixture`, because a stamped bundle
    /// that does not verify reads as foreign.
    private var ownToken: [String: Any] { [ShortcutConfig.installTokenInfoPlistKey: settings.installToken] }

    /// A shortcut this App Duplicator did not write (C3): unsigned and without this install's token, as a received or
    /// planted bundle would be.
    private func writeForeignShortcut(named name: String, engineVersion: Int = ShortcutConfig.currentEngineVersion) throws -> URL {
        var c = config(name: name)
        c.engineVersion = engineVersion
        return try writeShortcutBundle(named: name, in: out, config: c, engineVersion: engineVersion)
    }

    private func infoPlist(of bundle: URL) throws -> Data {
        try Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))
    }

    func testCreatedShortcutsAreOwnAndCarryThisInstallsToken() async throws {
        let created = await state.create(config: config())
        let record = try XCTUnwrap(library.record(for: try XCTUnwrap(created)))
        XCTAssertEqual(record.provenance, .own)
        let info = try XCTUnwrap(NSDictionary(contentsOf: record.bundleURL.appending(path: "Contents/Info.plist")))
        XCTAssertEqual(info[ShortcutConfig.installTokenInfoPlistKey] as? String, settings.installToken)
    }

    func testSavingAForeignShortcutWaitsForApprovalAndWritesNothing() async throws {
        let bundle = try writeForeignShortcut(named: "Planted")
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))
        XCTAssertEqual(record.provenance, .foreign(reason: "no install token; an ad hoc signature cannot show who built it"), "precondition: unsigned and tokenless")
        let before = try infoPlist(of: bundle)
        var edited = record.config
        edited.arguments = ["--edited"]

        let saved = await state.save(record: record, config: edited)

        XCTAssertFalse(saved, "a foreign shortcut is not rewritten before the user approves it")
        XCTAssertNil(state.pendingError, "a held save is not an error")
        let approval = try XCTUnwrap(state.pendingForeignApproval)
        XCTAssertEqual(approval.record.bundleURL, record.bundleURL)
        XCTAssertEqual(approval.config.arguments, ["--edited"], "the sheet shows the config the save would write")
        XCTAssertEqual(approval.signature, .unknown)
        XCTAssertEqual(try infoPlist(of: bundle), before, "nothing is written before approval")

        // Regenerate goes through the same gate.
        state.pendingForeignApproval = nil
        await state.regenerate(record)
        XCTAssertEqual(state.pendingForeignApproval?.config, record.config)
        XCTAssertEqual(try infoPlist(of: bundle), before)

        // "Review in Editor" drops the held save and shows the shortcut.
        state.selection = nil
        state.cancelForeignApproval()
        XCTAssertNil(state.pendingForeignApproval)
        XCTAssertEqual(state.selection, record.bundleURL)
        XCTAssertEqual(try infoPlist(of: bundle), before, "Review in Editor writes nothing")
        XCTAssertEqual(library.record(for: bundle)?.isForeign, true)
    }

    func testTrustAndRebuildWritesTheReviewedConfigAndMakesTheShortcutOwn() async throws {
        let bundle = try writeForeignShortcut(named: "Planted")
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))
        var edited = record.config
        edited.arguments = ["--reviewed"]
        _ = await state.save(record: record, config: edited)
        let approval = try XCTUnwrap(state.pendingForeignApproval)

        let approved = await state.approveForeignShortcut(approval)

        XCTAssertTrue(approved, state.pendingError?.message ?? "")
        XCTAssertNil(state.pendingForeignApproval)
        let after = try XCTUnwrap(library.record(for: bundle))
        XCTAssertEqual(after.provenance, .own, "the rewrite stamps this install's token")
        XCTAssertEqual(after.config.arguments, ["--reviewed"])
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")))
        XCTAssertEqual(info[ShortcutConfig.installTokenInfoPlistKey] as? String, settings.installToken)
        XCTAssertEqual(state.selection, after.bundleURL)

        // From then on a save is an ordinary save.
        var again = after.config
        again.arguments = ["--again"]
        let savedAgain = await state.save(record: after, config: again)
        XCTAssertTrue(savedAgain, state.pendingError?.message ?? "")
        XCTAssertNil(state.pendingForeignApproval)
        XCTAssertEqual(library.record(for: bundle)?.config.arguments, ["--again"])
    }

    /// The recipient flow the export sheet describes (C3): a received copy carries another install's token and the
    /// download's quarantine flag on every file. Trust and Rebuild assembles a fresh bundle, so it carries neither and
    /// is this install's shortcut from then on.
    func testTrustAndRebuildMakesAReceivedQuarantinedShortcutOwn() async throws {
        let otherInstall = [ShortcutConfig.installTokenInfoPlistKey: String(repeating: "ab", count: 32)]
        let bundle = try writeShortcutBundle(named: "Received", in: out, config: config(name: "Received"), extraInfo: otherInstall)
        let items = [bundle] + (FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        let flag = Array("0083;00000000;Safari;".utf8)
        for item in items {
            let result = item.withUnsafeFileSystemRepresentation {
                setxattr($0!, LibraryScanner.quarantineAttribute, flag, flag.count, 0, XATTR_NOFOLLOW)
            }
            XCTAssertEqual(result, 0, "setxattr failed on \(item.path)")
        }
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))
        XCTAssertEqual(record.foreignReason, "downloaded or received (quarantined)")

        _ = await state.save(record: record, config: record.config)
        let approval = try XCTUnwrap(state.pendingForeignApproval)
        let approved = await state.approveForeignShortcut(approval)

        XCTAssertTrue(approved, state.pendingError?.message ?? "")
        XCTAssertFalse(LibraryScanner.isQuarantined(bundle), "the rebuilt bundle is a fresh write, not the received files")
        XCTAssertEqual(library.record(for: bundle)?.provenance, .own)
    }

    func testRebuildAllSkipsShortcutsNotCreatedHereAndReportsThem() async throws {
        var mine = config(name: "A Mine")
        mine.engineVersion = 0
        try adHocSignFixture(try writeShortcutBundle(named: "A Mine", in: out, config: mine, engineVersion: 0, extraInfo: ownToken))
        let planted = try writeForeignShortcut(named: "B Planted", engineVersion: 0)
        let plantedInfo = try infoPlist(of: planted)
        await library.rescan()
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["A Mine", "B Planted"])

        let results = await state.rebuildAll()

        XCTAssertEqual(results.map(\.name), ["A Mine", "B Planted"])
        XCTAssertEqual(results.map(\.outcome), [.rebuilt, .skipped("no install token; an ad hoc signature cannot show who built it")])
        XCTAssertEqual(try infoPlist(of: planted), plantedInfo, "a skipped shortcut is not rewritten or re-signed")
        XCTAssertEqual(library.recordsNeedingRebuild.map(\.name), ["B Planted"])
        XCTAssertEqual(library.record(for: planted)?.isForeign, true)
        XCTAssertNil(state.pendingForeignApproval, "Rebuild All never asks; it reports the skipped shortcuts")
        XCTAssertNil(state.pendingError)
        XCTAssertTrue(RebuildSummary.text(for: results).hasSuffix("1 shortcut skipped: not created by this App Duplicator \u{2014} open each to review."))
    }

    func testDuplicateRefusesAShortcutNotCreatedHere() async throws {
        let bundle = try writeForeignShortcut(named: "Planted")
        await library.rescan()
        let record = try XCTUnwrap(library.record(for: bundle))

        await state.duplicate(record, newName: "Planted Copy")

        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appending(path: "Planted Copy.app").path),
                       "a duplicate would be signed and stamped as this install's own without a review")
        XCTAssertEqual(state.pendingError?.context, "Could not duplicate shortcut")
        let message = try XCTUnwrap(state.pendingError?.message)
        XCTAssertTrue(message.contains("Planted") && message.contains("Trust and Rebuild"), message)
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
        try adHocSignFixture(try writeShortcutBundle(named: "Old One", in: out, config: old, engineVersion: 0, extraInfo: ownToken))
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
        try adHocSignFixture(try writeShortcutBundle(named: "A Broken", in: out, config: broken, engineVersion: 0, extraInfo: ownToken))
        var stale = config(name: "B Stale")
        stale.engineVersion = 0
        try adHocSignFixture(try writeShortcutBundle(named: "B Stale", in: out, config: stale, engineVersion: 0, extraInfo: ownToken))
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

    func testExportWarnsInsideALibraryFolderAndMovesAnExistingDestinationToTheTrash() async throws {
        let created = await state.create(config: config())
        let record = try XCTUnwrap(library.record(for: try XCTUnwrap(created)))
        let exports = dir.appending(path: "Exports", directoryHint: .isDirectory)

        let warning = try XCTUnwrap(state.exportWarning(for: out.appending(path: "Work Copy.app")))
        XCTAssertTrue(warning.contains("Work Copy.app") && warning.contains("second shortcut"), warning)
        XCTAssertNotNil(state.exportWarning(for: dir.appending(path: "OUT/Work Copy.app")), "library folders compare case-insensitively")
        XCTAssertNil(state.exportWarning(for: exports.appending(path: "Work Copy.app")))
        XCTAssertNil(state.exportWarning(for: out.appending(path: "Nested/Work Copy.app")), "the library scans only a folder's direct children")

        let destination = exports.appending(path: "Work.app", directoryHint: .isDirectory)
        // The existing destination is a previous export (a shortcut bundle); a plain app there would be refused.
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: record.bundleURL, to: destination)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))
        let exported = await state.exportCopy(record, to: destination)

        let outcome = try XCTUnwrap(exported)
        let trashed = try XCTUnwrap(outcome.trashedExisting)
        addTeardownBlock { try FileManager.default.removeItem(at: trashed) }
        XCTAssertEqual(try Data(contentsOf: trashed.appending(path: "old-marker")), Data("old".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
        XCTAssertNil(state.pendingError)
    }

    func testValidateDataPathRefusesScannedShortcutsAndTheTargetAppsOwnData() async throws {
        let created = await state.create(config: config())
        let bundle = try XCTUnwrap(created)
        guard case .failure(.overlapsShortcut) = state.validateDataPath(bundle.appending(path: "Contents/Data").path, targetPath: target.path, excluding: nil) else {
            return XCTFail("a folder inside a scanned shortcut is refused")
        }
        // Read-only: the app is not sandboxed, so this is the real home; these folders are only resolved, never created.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["Library/Application Support/Target", "Library/Caches/com.example.target"] {
            let result = state.validateDataPath(home.appending(path: folder).path, targetPath: target.path, excluding: nil, targetBundleIdentifier: "com.example.target")
            guard case .failure(.targetAppData) = result else { return XCTFail("\(folder): \(result)") }
        }
        XCTAssertEqual(TargetResolver().resolvedPath(targetPath: target.path, targetBundleIdentifier: "com.example.target"), target.path)
        XCTAssertNil(TargetResolver().resolvedPath(targetPath: target.path, targetBundleIdentifier: ""))
    }
}
