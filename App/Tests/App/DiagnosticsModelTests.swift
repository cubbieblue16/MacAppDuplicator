import CompatProfiles
import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class DiagnosticsModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    func testMasksSecretsAndIncludesLogTail() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.environment = ["API_TOKEN": "hunter2", "PLAIN": "ok"]
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "line1\nline2\n".write(to: logs.appending(path: "Target Work.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))
        XCTAssertEqual(model.shortcutName, "Target Work")
        XCTAssertEqual(model.executablePath, target.appending(path: "Contents/MacOS/Target").path)
        XCTAssertEqual(model.launchMode, "System Launch")
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.logLines, ["line1", "line2"])
        let env = Dictionary(uniqueKeysWithValues: model.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(env["PLAIN"], "ok")
        XCTAssertTrue(model.reportText.contains("API_TOKEN=\(SecretMasking.maskedValue)"))
        XCTAssertFalse(model.reportText.contains("hunter2"))
        XCTAssertTrue(model.reportText.contains("line2"))
    }

    func testMissingTargetProducesPlanError() throws {
        let config = makeConfig(name: "Gone", targetPath: dir.appending(path: "Missing.app").path)
        let bundle = try writeShortcutBundle(named: "Gone", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertNotNil(model.planError)
        XCTAssertEqual(model.logLines, [])
        XCTAssertTrue(model.reportText.contains("Launch plan error"))
    }

    // Final review M13 / spec §7: Diagnostics shows the target path the launcher would resolve, not only the stored one.

    func testResolvedTargetEqualsTheStoredPathWhenItStillMatches() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let config = makeConfig(name: "Target Work", targetPath: target.path)
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertEqual(model.resolvedTargetPath, target.path)
        XCTAssertEqual(model.storedTargetPath, target.path)
        XCTAssertNil(model.planError)
        XCTAssertTrue(model.reportText.contains("Target: \(target.path)"))
        XCTAssertFalse(model.reportText.contains("Stored target path"))
    }

    func testUnresolvableTargetIsReportedAsNotFound() throws {
        let missing = dir.appending(path: "Missing.app").path
        // A bundle id no app registers, so the Launch Services fallback finds nothing either.
        let config = makeConfig(name: "Gone", targetPath: missing, targetBundleIdentifier: "com.example.unregistered-\(UUID().uuidString)")
        let bundle = try writeShortcutBundle(named: "Gone", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertNil(model.resolvedTargetPath)
        XCTAssertEqual(model.storedTargetPath, missing)
        XCTAssertNotNil(model.planError)
        XCTAssertTrue(model.reportText.contains("Target: not found"))
        XCTAssertTrue(model.reportText.contains("Stored target path: \(missing)"))
    }

    /// The launcher falls back to Launch Services when the stored path is stale (spec §3.4 step 3). Read-only lookup of an
    /// app every Mac has; nothing is launched or written.
    func testStaleStoredPathResolvesThroughLaunchServices() throws {
        let stale = dir.appending(path: "Moved/TextEdit.app").path
        let config = makeConfig(name: "Editor Copy", targetPath: stale, targetBundleIdentifier: "com.apple.TextEdit")
        let bundle = try writeShortcutBundle(named: "Editor Copy", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        let resolved = try XCTUnwrap(model.resolvedTargetPath)
        XCTAssertTrue(resolved.hasSuffix("/TextEdit.app"), resolved)
        XCTAssertNotEqual(resolved, stale)
        XCTAssertEqual(model.storedTargetPath, stale)
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.launchMode, "System Launch")
        XCTAssertTrue(model.reportText.contains("Target: \(resolved)"))
        XCTAssertTrue(model.reportText.contains("Stored target path: \(stale)"))
    }

    func testMasksSecretArgumentsAndOldLogLinesAndShowsTheEngineVersion() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.arguments = ["--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible"]
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config, engineVersion: 0)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        // Lines a launcher built before argv masking wrote.
        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "2026-10-01T09:00:00Z argv --api-key hunter2 --token=not-a-real-token\n2026-10-01T09:00:00Z env GITHUB_TOKEN=leaked\n"
            .write(to: logs.appending(path: "Target Work.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.arguments, ["--api-key", "••••••", "--token=••••••", "--plain", "visible"])
        XCTAssertEqual(model.engineVersion, 0)
        XCTAssertEqual(model.logLines, [
            "2026-10-01T09:00:00Z argv --api-key •••••• --token=••••••",
            "2026-10-01T09:00:00Z env GITHUB_TOKEN=••••••",
        ])
        let report = model.reportText
        XCTAssertTrue(report.contains("Engine version: 0 (current \(ShortcutConfig.currentEngineVersion))"), report)
        for secret in ["hunter2", "not-a-real-token", "leaked"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
    }

    func testShowsTheProfileMatchNotesAndFamilyWithoutSecrets() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let config = makeConfig(name: "Target Work", targetPath: target.path)
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))
        let catalog = ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09", apps: [
            "com.example.target": AppProfile(name: "Target", status: .partial, family: .electron,
                                             args: ["--api-key", "hunter2", "--plain"], env: ["API_TOKEN": "leaked", "PLAIN": "ok"],
                                             notes: "Opens one window per data folder."),
        ]), source: .cached)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir), profileCatalog: catalog)
        XCTAssertNil(model.planError)
        XCTAssertEqual(model.profileMatch, "com.example.target · Partial · updated 2026-10-09 · cached")
        XCTAssertEqual(model.profileRows, ProfileSummary.rows(for: catalog.profile(forBundleIdentifier: "com.example.target"), detectedFamily: .native))
        let report = model.reportText
        XCTAssertTrue(report.contains("Profile: com.example.target · Partial · updated 2026-10-09 · cached"), report)
        XCTAssertTrue(report.contains("  Notes: Opens one window per data folder."), report)
        XCTAssertTrue(report.contains("  Family note: The profile lists family Electron but App Duplicator detected Native; launch settings follow the detected family."), report)
        for secret in ["hunter2", "leaked"] {
            XCTAssertFalse(report.contains(secret), secret)
        }

        // No catalog loaded, and a catalog without this app.
        let unloaded = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertEqual(unloaded.profileMatch, "No profiles loaded.")
        XCTAssertEqual(unloaded.profileRows, [])
        let other = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir),
                                          profileCatalog: ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09"), source: .bundled))
        XCTAssertEqual(other.profileMatch, "No profile for com.example.target (profiles updated 2026-10-09, bundled)")

        // The failed path still reports the match; no family is detected, so there is no family note.
        let goneID = "com.example.unregistered-\(UUID().uuidString)"
        let gone = makeConfig(name: "Gone", targetPath: dir.appending(path: "Missing.app").path, targetBundleIdentifier: goneID)
        let goneRecord = try XCTUnwrap(LibraryScanner.record(forBundleAt: try writeShortcutBundle(named: "Gone", in: dir, config: gone), fileManager: .default))
        let goneCatalog = ProfileCatalog(document: ProfilesDocument(updated: "2026-10-09", apps: [goneID: AppProfile(name: "Gone", status: .verified, family: .electron)]), source: .bundled)
        let failed = DiagnosticsModel.make(record: goneRecord, logReader: LogReader(folder: dir), profileCatalog: goneCatalog)
        XCTAssertNotNil(failed.planError)
        XCTAssertEqual(failed.profileMatch, "\(goneID) · Verified · updated 2026-10-09 · bundled")
        XCTAssertFalse(failed.profileRows.contains { $0.label == "Family note" })
        XCTAssertTrue(failed.reportText.contains("Profile: \(goneID) · Verified"), failed.reportText)
    }

    // MARK: Phase 4 web apps

    func testWebAppModelShowsTheRedactedAddressAndNoTargetPlan() throws {
        let storeID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        var config = makeWebShortcutConfig(
            name: "Chat Inbox", url: "https://chat.example.com/inbox?token=abc#top", dataStoreID: storeID,
            menuBarIcon: true, backgroundMode: true)
        config.webApp?.userAgent = .chrome
        config.webApp?.extraHosts = ["login.example.com"]
        let bundle = try writeShortcutBundle(named: "Chat Inbox", in: dir, config: config)
        let record = try LibraryScanner.record(forBundleAt: bundle, fileManager: .default)
        let logs = dir.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "started\nbadge=3\n".write(to: logs.appending(path: "Chat Inbox.log"), atomically: true, encoding: .utf8)

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: logs))

        XCTAssertNil(model.planError, "a web app has no launch plan to fail")
        XCTAssertEqual(model.launchMode, "Web Shell")
        XCTAssertNil(model.resolvedTargetPath)
        XCTAssertEqual(model.logLines, ["started", "badge=3"])
        let web = try XCTUnwrap(model.web)
        XCTAssertEqual(web.url, "https://chat.example.com/inbox", "query and fragment are dropped: the report gets pasted into tickets")
        XCTAssertEqual(web.userAgent, "Chrome")
        XCTAssertEqual(web.dataStoreID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(web.backgroundMode, "On")
        XCTAssertEqual(web.menuBarIcon, "On")
        XCTAssertEqual(web.badgePattern, "\(BadgeTitleParser.defaultPattern) (default)")
        XCTAssertEqual(web.extraHosts, ["login.example.com"])
        XCTAssertEqual(web.zoom, "100%")

        let report = model.reportText
        XCTAssertTrue(report.contains("URL: https://chat.example.com/inbox\n"))
        XCTAssertTrue(report.contains("User agent: Chrome"))
        XCTAssertTrue(report.contains("Data store id: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(report.contains("Also open in app: login.example.com"))
        XCTAssertTrue(report.contains("Recent log (last 2 lines):\nstarted\nbadge=3"))
        XCTAssertFalse(report.contains("token=abc"), "the address query must not reach the report")
        XCTAssertFalse(report.contains("Target:"))
        XCTAssertFalse(report.contains("Arguments:"))
        XCTAssertFalse(report.contains("Launch plan error"))
    }

    func testWebAppBadgePatternTextSaysWhichPatternIsInUse() throws {
        var config = makeWebShortcutConfig(name: "Chat Badge")
        config.webApp?.badgeRegex = #"\[(\d+)\]"#
        let good = try LibraryScanner.record(forBundleAt: writeShortcutBundle(named: "Chat Badge", in: dir, config: config), fileManager: .default)
        XCTAssertEqual(DiagnosticsModel.make(record: good, logReader: LogReader(folder: dir)).web?.badgePattern, #"\[(\d+)\]"#)

        // Written to a second folder so both bundles can be called "Chat Badge".
        let other = dir.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        config.webApp?.badgeRegex = "("
        let bad = try LibraryScanner.record(forBundleAt: writeShortcutBundle(named: "Chat Badge", in: other, config: config), fileManager: .default)
        XCTAssertEqual(
            DiagnosticsModel.make(record: bad, logReader: LogReader(folder: dir)).web?.badgePattern,
            "\(BadgeTitleParser.defaultPattern) (the saved pattern is invalid; the default is used)")
    }

    func testRedactedURLDropsCredentialsQueryAndFragment() {
        XCTAssertEqual(
            DiagnosticsModel.redactedURL("https://user:secret@chat.example.com:8443/inbox/?token=abc#top"),
            "https://chat.example.com:8443/inbox/")
        XCTAssertEqual(DiagnosticsModel.redactedURL("https://chat.example.com"), "https://chat.example.com")
        XCTAssertEqual(DiagnosticsModel.redactedURL("not a url"), "(unreadable address)")
    }

    func testWebAppWithoutSettingsReportsAPlanErrorInsteadOfCrashing() throws {
        var config = makeWebShortcutConfig(name: "Chat Broken")
        config.webApp = nil
        let record = ShortcutRecord(
            bundleURL: dir.appending(path: "Chat Broken.app"), config: config, engineVersion: ShortcutConfig.currentEngineVersion,
            iconURL: nil, targetVersion: nil, targetExists: true, modifiedDate: Date(), provenance: .own)
        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))
        XCTAssertEqual(model.web?.url, "Not available (configuration missing)")
        XCTAssertEqual(model.web?.dataStoreID, "Not available (configuration missing)")
        XCTAssertEqual(model.planError, "This web app has no web address saved. Regenerate the shortcut or recreate it.")
        XCTAssertTrue(model.reportText.contains("Launch plan error: This web app has no web address saved."))
    }

    func testNativeShortcutShowsHelperRows() throws {
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        let data = dir.appending(path: "Data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(CanonicalPath(data.path).isInside(CanonicalPath(realHome.path)), "the test folder must lie outside the home folder")
        var config = makeConfig(name: "Target Work", targetPath: target.path)
        config.dataMode = .homeOverride
        config.dataPath = data.path
        config.menuBarIcon = true
        config.eraseOnQuit = true
        config.newWindowCommand = "open -na {target} --args --api-key hunter2"
        config.languageCode = "fr"
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))

        XCTAssertNil(model.planError)
        let targetPath = try XCTUnwrap(model.resolvedTargetPath)
        XCTAssertEqual(model.helperRows, [
            ProfileSummary.Row(label: "Menu bar icon", value: "On"),
            ProfileSummary.Row(label: "Erase on quit", value: "On, but the folder is never erased: the folder is outside the home folder"),
            ProfileSummary.Row(label: "New Window command", value: "/usr/bin/env open -na \(targetPath) --args --api-key \(SecretMasking.maskedValue)"),
            ProfileSummary.Row(label: "Language", value: "fr"),
        ])
        for row in model.helperRows {
            XCTAssertTrue(model.reportText.contains("\(row.label): \(row.value)"), row.label)
        }
        XCTAssertFalse(model.reportText.contains("hunter2"))
    }

    func testHelperRowsSurviveAPlanError() throws {
        let missing = dir.appending(path: "Missing.app").path
        var config = makeConfig(name: "Target Work", targetPath: missing, targetBundleIdentifier: "com.example.unregistered-\(UUID().uuidString)")
        config.menuBarIcon = true
        config.eraseOnQuit = false
        config.languageCode = nil
        config.newWindowCommand = "open -na {target}"
        let bundle = try writeShortcutBundle(named: "Target Work", in: dir, config: config)
        let record = try XCTUnwrap(LibraryScanner.record(forBundleAt: bundle, fileManager: .default))

        let model = DiagnosticsModel.make(record: record, logReader: LogReader(folder: dir))

        XCTAssertNotNil(model.planError)
        XCTAssertEqual(model.helperRows, [
            ProfileSummary.Row(label: "Menu bar icon", value: "On"),
            ProfileSummary.Row(label: "Erase on quit", value: "Off"),
            ProfileSummary.Row(label: "New Window command", value: "/usr/bin/env open -na \(missing)"),
            ProfileSummary.Row(label: "Language", value: "System"),
        ])
        XCTAssertTrue(model.reportText.contains("Menu bar icon: On"))
    }
}
