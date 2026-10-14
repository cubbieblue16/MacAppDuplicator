import Darwin
import XCTest
@testable import DuplicatorCore

/// C4 (location rules, ownership marker) and R4 (owner and mode of a reused data folder).
final class DataFolderOwnershipTests: XCTestCase {
    private let fileManager = FileManager.default
    private let bundle = "com.mikekuta.appduplicator.notes"
    private let home = ["Users", "test"]

    private func shape(_ relative: String...) -> EraseOnQuitRefusal? {
        DataPathRules.refusal(home + relative, home: home)
    }

    private func resolved(_ url: URL) -> String {
        guard let pointer = realpath(url.path, nil) else { return url.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func makeHome() throws -> URL {
        URL(fileURLWithPath: resolved(try makeTemporaryDirectory()), isDirectory: true)
    }

    // MARK: C4 location rules

    func testRefusesSyncedContainerAndApplicationSupportSubtrees() {
        XCTAssertEqual(shape("Library", "Mobile Documents", "com~apple~CloudDocs"), .protectedSubtree("~/Library/Mobile Documents"))
        XCTAssertEqual(shape("Library", "Mobile Documents", "com~apple~CloudDocs", "proj", "data"), .protectedSubtree("~/Library/Mobile Documents"))
        XCTAssertEqual(shape("Library", "CloudStorage", "Dropbox", "x"), .protectedSubtree("~/Library/CloudStorage"))
        XCTAssertEqual(shape("Library", "Containers", "com.apple.Notes", "Data"), .protectedSubtree("~/Library/Containers"))
        XCTAssertEqual(shape("Library", "Group Containers", "group.x", "y"), .protectedSubtree("~/Library/Group Containers"))
        XCTAssertEqual(shape("library", "CLOUDSTORAGE", "OneDrive"), .protectedSubtree("~/Library/CloudStorage"))
        XCTAssertEqual(shape("Library", "Application Support", "Slack"), .protectedSubtree("~/Library/Application Support"))
        XCTAssertEqual(shape("Library", "Application Support", "Slack", "storage"), .protectedSubtree("~/Library/Application Support"))
    }

    func testApplicationSupportStaysOpenInsideTheAppsOwnDataRoot() {
        XCTAssertNil(shape("Library", "Application Support", "App Duplicator", "notes"))
        XCTAssertNil(shape("Library", "Application Support", "app duplicator", "notes", "deeper"))
        XCTAssertEqual(shape("Library", "Application Support", "App Duplicator"), .dataRoot)
    }

    func testRefusesTopLevelChildrenOfDocumentsDesktopAndDownloads() {
        XCTAssertEqual(shape("Documents", "Project"), .protectedSubtree("~/Documents"))
        XCTAssertEqual(shape("documents", "Project"), .protectedSubtree("~/Documents"))
        XCTAssertEqual(shape("Desktop", "Stuff"), .protectedSubtree("~/Desktop"))
        XCTAssertEqual(shape("Downloads", "Stuff"), .protectedSubtree("~/Downloads"))
        XCTAssertNil(shape("Documents", "Project", "data"))
        XCTAssertNil(shape("Desktop", "Stuff", "data"))
        XCTAssertNil(shape("Work", "Notes"))
    }

    func testOnlyDeepDocumentsFoldersNeedTheMarkerAtPickTime() {
        XCTAssertTrue(DataPathRules.needsOwnerMarker(home + ["Documents", "Project", "data"], home: home))
        XCTAssertFalse(DataPathRules.needsOwnerMarker(home + ["Work", "Notes"], home: home))
        XCTAssertFalse(DataPathRules.needsOwnerMarker(home + ["Documents", "Project"], home: home))
    }

    func testEraseRefusesTheNewLocationsOnDisk() throws {
        let home = try makeHome()
        let cases: [(String, EraseOnQuitRefusal)] = [
            ("Library/CloudStorage/Dropbox/work", .protectedSubtree("~/Library/CloudStorage")),
            ("Library/Mobile Documents/com~apple~CloudDocs/x", .protectedSubtree("~/Library/Mobile Documents")),
            ("Library/Application Support/Slack/data", .protectedSubtree("~/Library/Application Support")),
            ("Documents/Project", .protectedSubtree("~/Documents")),
            ("Downloads/Stuff", .protectedSubtree("~/Downloads")),
        ]
        for (relative, expected) in cases {
            let folder = home.appending(path: relative, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try DataFolderOwnership.claim(folder, bundleIdentifier: bundle)
            XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: folder.path, home: home, bundleIdentifier: bundle), .failure(expected), relative)
        }
    }

    // MARK: C4 ownership marker

    func testEraseRequiresAMarkerNamingTheShortcut() throws {
        let home = try makeHome()
        let folder = home.appending(path: "Work/Notes", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: folder.path, home: home, bundleIdentifier: bundle), .failure(.ownerMarkerMissing))

        try DataFolderOwnership.claim(folder, bundleIdentifier: "com.mikekuta.appduplicator.other")
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: folder.path, home: home, bundleIdentifier: bundle), .failure(.ownerMarkerMismatch))

        try Data((bundle + "\n").utf8).write(to: folder.appending(path: DataFolderOwnership.markerFileName))
        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: folder.path, home: home, bundleIdentifier: bundle).map(\.path), .success(resolved(folder)))
    }

    func testAMarkerThatIsASymbolicLinkIsNotTrusted() throws {
        let home = try makeHome()
        let folder = home.appending(path: "Work/Notes", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = home.appending(path: "Work/owner.txt", directoryHint: .notDirectory)
        try Data(bundle.utf8).write(to: elsewhere)
        try fileManager.createSymbolicLink(at: folder.appending(path: DataFolderOwnership.markerFileName), withDestinationURL: elsewhere)

        XCTAssertEqual(EraseOnQuitPolicy.check(dataPath: folder.path, home: home, bundleIdentifier: bundle), .failure(.ownerMarkerMissing))
    }

    func testClaimNeverRewritesAnExistingMarker() throws {
        let folder = try makeTemporaryDirectory()
        try DataFolderOwnership.claim(folder, bundleIdentifier: "first")
        try DataFolderOwnership.claim(folder, bundleIdentifier: "second")
        XCTAssertEqual(DataFolderOwnership.owner(of: folder), "first")
    }

    func testCanClaimOnlyNewEmptyOwnedOrDataRootFolders() throws {
        let home = try makeHome()
        let missing = home.appending(path: "Work/New", directoryHint: .isDirectory)
        XCTAssertTrue(DataFolderOwnership.canClaim(missing, home: home))

        let empty = home.appending(path: "Work/Empty", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appending(path: ".DS_Store"))
        XCTAssertTrue(DataFolderOwnership.canClaim(empty, home: home))

        let foreign = home.appending(path: "Work/Foreign", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: foreign.appending(path: "important.txt"))
        XCTAssertFalse(DataFolderOwnership.canClaim(foreign, home: home), "A populated folder App Duplicator did not build is never adopted")

        let inRoot = home.appending(path: "Library/Application Support/App Duplicator/notes", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: inRoot, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inRoot.appending(path: "legacy.txt"))
        XCTAssertTrue(DataFolderOwnership.canClaim(inRoot, home: home))

        let tree = home.appending(path: "Work/Tree", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data().write(to: tree.appending(path: HomeTreeBuilder.markerFileName))
        XCTAssertTrue(DataFolderOwnership.canClaim(tree, home: home))
    }

    func testErasingKeepsTheFolderThatHeldTheMarker() throws {
        let folder = try makeTemporaryDirectory().appending(path: "Data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try DataFolderOwnership.claim(folder, bundleIdentifier: bundle)
        try Data("a".utf8).write(to: folder.appending(path: "a.txt"))

        let outcome = EraseOnQuitPerformer.erase(at: folder)

        XCTAssertEqual(outcome, EraseOnQuitOutcome(removed: 2, failures: []))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue, "The data folder itself must survive the erase")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: R4 owner and mode

    func testRefusesAnExistingFolderOthersCanWrite() throws {
        let folder = try makeTemporaryDirectory().appending(path: "shared", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        for mode in [mode_t(0o777), 0o770, 0o707, 0o1777] {
            XCTAssertEqual(chmod(folder.path, mode), 0)
            XCTAssertThrowsError(try DataFolderOwnership.verifyUsable(folder), String(mode, radix: 8)) { error in
                XCTAssertEqual(error as? DataFolderError, .writableByOthers(folder.path))
            }
        }
        for mode in [mode_t(0o700), 0o755, 0o750] {
            XCTAssertEqual(chmod(folder.path, mode), 0)
            XCTAssertNoThrow(try DataFolderOwnership.verifyUsable(folder), String(mode, radix: 8))
        }
    }

    func testRefusesAFolderOwnedBySomeoneElse() throws {
        let folder = try makeTemporaryDirectory()
        XCTAssertThrowsError(try DataFolderOwnership.verifyUsable(folder, userID: getuid() &+ 1)) { error in
            XCTAssertEqual(error as? DataFolderError, .notOwnedByCurrentUser(folder.path))
        }
    }

    func testRefusesAFileWhereAFolderIsExpected() throws {
        let file = try makeTemporaryDirectory().appending(path: "file", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try DataFolderOwnership.verifyUsable(file)) { error in
            XCTAssertEqual(error as? DataFolderError, .notADirectory(file.path))
        }
    }

    func testCreatesDataFoldersPrivate() throws {
        let folder = try makeTemporaryDirectory().appending(path: "a/b/data", directoryHint: .isDirectory)
        try DataFolderOwnership.createOrVerify(folder)
        let attributes = try fileManager.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testHomeTreeBuilderRefusesAPlantedWorldWritableFolder() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = sandbox.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        let planted = sandbox.appending(path: "planted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: planted, withIntermediateDirectories: true)
        try Data().write(to: planted.appending(path: HomeTreeBuilder.markerFileName))
        try Data("[core]\n".utf8).write(to: planted.appending(path: ".gitconfig"))
        XCTAssertEqual(chmod(planted.path, 0o777), 0)
        let builder = HomeTreeBuilder(realHome: realHome)

        XCTAssertThrowsError(try builder.materialize(at: planted)) { error in
            XCTAssertEqual(error as? DataFolderError, .writableByOthers(planted.standardizedFileURL.path))
        }

        XCTAssertEqual(chmod(planted.path, 0o700), 0)
        XCTAssertEqual(try builder.materialize(at: planted), planted.standardizedFileURL)
    }

    func testHomeTreeBuilderRefusesAWorldWritableUserSubfolder() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = sandbox.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        let root = sandbox.appending(path: "data", directoryHint: .isDirectory)
        let sub = root.appending(path: NSUserName(), directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appending(path: HomeTreeBuilder.markerFileName))
        try Data("x".utf8).write(to: root.appending(path: "other.txt"))
        XCTAssertEqual(chmod(sub.path, 0o777), 0)

        XCTAssertThrowsError(try HomeTreeBuilder(realHome: realHome).materialize(at: root)) { error in
            XCTAssertEqual(error as? DataFolderError, .writableByOthers(sub.standardizedFileURL.path))
        }
    }

    // MARK: Launcher writes the marker

    func testLaunchPreparerClaimsANewHomeOverrideFolder() throws {
        let root = try makeTemporaryDirectory()
        let realHome = root.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        let target = try FixtureBundle(name: "Target").writeSigned(in: root)
        let data = root.appending(path: "Work/data", directoryHint: .isDirectory)
        let config = ShortcutConfig(
            name: "Notes", slug: "notes", bundleIdentifier: bundle, targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture", dataMode: .homeOverride, dataPath: data.path
        )

        _ = try LaunchPreparer(realHome: realHome).prepare(
            infoDictionary: ["MADConfig": config.plistDictionary()],
            shortcutBundleURL: root.appending(path: "Shortcut.app", directoryHint: .isDirectory),
            baseEnvironment: [:]
        )

        XCTAssertEqual(DataFolderOwnership.owner(of: data), bundle)
        XCTAssertTrue(fileManager.fileExists(atPath: data.appending(path: HomeTreeBuilder.markerFileName).path), "The HOME tree stays in the folder itself")
        let attributes = try fileManager.attributesOfItem(atPath: data.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLaunchPreparerDoesNotClaimAPopulatedFolderItDidNotBuild() throws {
        let root = try makeTemporaryDirectory()
        let realHome = root.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        let target = try FixtureBundle(name: "Target").writeSigned(in: root)
        let data = root.appending(path: "Work/precious", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: data.appending(path: "thesis.txt"))
        let config = ShortcutConfig(
            name: "Notes", slug: "notes", bundleIdentifier: bundle, targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture", dataMode: .homeOverride, dataPath: data.path
        )

        _ = try LaunchPreparer(realHome: realHome).prepare(
            infoDictionary: ["MADConfig": config.plistDictionary()],
            shortcutBundleURL: root.appending(path: "Shortcut.app", directoryHint: .isDirectory),
            baseEnvironment: [:]
        )

        XCTAssertNil(DataFolderOwnership.owner(of: data))
    }

    func testLaunchPreparerRefusesAWorldWritableDataFolder() throws {
        let root = try makeTemporaryDirectory()
        let realHome = root.appending(path: "realhome", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome, withIntermediateDirectories: true)
        let target = try FixtureBundle(name: "Target").writeSigned(in: root)
        let data = root.appending(path: "Work/open", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(data.path, 0o777), 0)
        let config = ShortcutConfig(
            name: "Notes", slug: "notes", bundleIdentifier: bundle, targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture", dataMode: .homeOverride, dataPath: data.path
        )

        XCTAssertThrowsError(try LaunchPreparer(realHome: realHome).prepare(
            infoDictionary: ["MADConfig": config.plistDictionary()],
            shortcutBundleURL: root.appending(path: "Shortcut.app", directoryHint: .isDirectory),
            baseEnvironment: [:]
        )) { error in
            guard case LauncherError.dataPathNotWritable = error else { return XCTFail("\(error)") }
        }
    }
}
