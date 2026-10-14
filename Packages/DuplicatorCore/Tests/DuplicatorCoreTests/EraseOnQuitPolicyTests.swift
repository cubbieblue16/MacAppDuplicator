import Darwin
import XCTest
@testable import DuplicatorCore

final class EraseOnQuitPolicyTests: XCTestCase {
    /// `realpath(3)` of an existing path, the form `check` returns (`/var/folders/…` becomes `/private/var/folders/…`).
    private func resolved(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else {
            throw FixtureError(description: "realpath failed for \(url.path): errno \(errno)")
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static let bundleIdentifier = "com.mikekuta.appduplicator.test"

    /// `EraseOnQuitPolicy.check` for the test shortcut.
    private func check(dataPath: String, home: URL) -> Result<URL, EraseOnQuitRefusal> {
        EraseOnQuitPolicy.check(dataPath: dataPath, home: home, bundleIdentifier: Self.bundleIdentifier)
    }

    /// Creates `url` with the ownership marker App Duplicator would have written.
    @discardableResult
    private func makeFolder(_ url: URL, marker: String? = EraseOnQuitPolicyTests.bundleIdentifier) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let marker {
            try Data(marker.utf8).write(to: url.appending(path: DataFolderOwnership.markerFileName))
        }
        return url
    }

    private func defaultFolder(slug: String, home: URL) -> URL {
        URL(fileURLWithPath: ShortcutConfig.defaultDataPath(forSlug: slug, home: home), isDirectory: true)
    }

    func testAcceptsDefaultAndCustomFoldersAndReturnsTheResolvedURL() throws {
        let home = try makeTemporaryDirectory()
        let notes = try makeFolder(defaultFolder(slug: "notes-work", home: home))
        let custom = try makeFolder(home.appending(path: "Work/Notes Data", directoryHint: .isDirectory))

        XCTAssertEqual(check(dataPath: notes.path, home: home).map(\.path), .success(try resolved(notes)))
        XCTAssertEqual(check(dataPath: custom.path + "/", home: home).map(\.path), .success(try resolved(custom)))
    }

    func testRefusesMalformedMissingAndUnresolvablePaths() throws {
        let home = try makeTemporaryDirectory()
        let notes = try makeFolder(home.appending(path: "Work/Notes", directoryHint: .isDirectory))

        XCTAssertEqual(check(dataPath: "", home: home), .failure(.malformedPath))
        XCTAssertEqual(check(dataPath: "/", home: home), .failure(.malformedPath))
        XCTAssertEqual(check(dataPath: "Work/Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(check(dataPath: home.path + "/Work/Notes/../Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(check(dataPath: home.path + "/Work/./Notes", home: home), .failure(.malformedPath))
        XCTAssertEqual(check(dataPath: home.path + "/Work/Missing", home: home), .failure(.missing))
        XCTAssertEqual(
            check(dataPath: notes.path, home: home.appending(path: "No Such Home", directoryHint: .isDirectory)),
            .failure(.homeUnresolvable)
        )
    }

    func testRefusesADataFolderThatIsASymbolicLinkOrAFile() throws {
        let home = try makeTemporaryDirectory()
        let real = try makeFolder(home.appending(path: "Work/Real", directoryHint: .isDirectory))
        let root = try makeFolder(defaultFolder(slug: "linked", home: home).deletingLastPathComponent())
        let link = root.appending(path: "linked", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = home.appending(path: "Work/notes.txt", directoryHint: .notDirectory)
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(check(dataPath: link.path, home: home), .failure(.symbolicLink))
        XCTAssertEqual(check(dataPath: link.path + "/", home: home), .failure(.symbolicLink))
        XCTAssertEqual(check(dataPath: file.path, home: home), .failure(.notDirectory))
    }

    func testResolvesSymbolicLinksAboveTheFolderBeforeCheckingWhereItIs() throws {
        let home = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        try makeFolder(outside.appending(path: "a/b", directoryHint: .isDirectory))
        let work = try makeFolder(home.appending(path: "Work", directoryHint: .isDirectory))
        try FileManager.default.createSymbolicLink(at: work.appending(path: "Escape", directoryHint: .notDirectory), withDestinationURL: outside)
        let notes = try makeFolder(defaultFolder(slug: "notes", home: home))
        try FileManager.default.createSymbolicLink(
            at: work.appending(path: "RootLink", directoryHint: .notDirectory),
            withDestinationURL: notes.deletingLastPathComponent()
        )

        XCTAssertEqual(check(dataPath: work.path + "/Escape/a/b", home: home), .failure(.outsideHome))
        XCTAssertEqual(check(dataPath: outside.path + "/a/b", home: home), .failure(.outsideHome))
        XCTAssertEqual(
            check(dataPath: work.path + "/RootLink/notes", home: home).map(\.path),
            .success(try resolved(notes))
        )
    }

    func testRefusesTheHomeItsDirectChildrenLibraryChildrenAndTheDataRootOnDisk() throws {
        let home = try makeTemporaryDirectory()
        let root = try makeFolder(defaultFolder(slug: "notes", home: home).deletingLastPathComponent())
        let expectations: [(relativePath: String, refusal: EraseOnQuitRefusal)] = [
            ("", .home),
            ("Documents", .protectedFolder("Documents")),
            ("DOWNLOADS", .protectedFolder("Downloads")),
            ("Library", .protectedFolder("Library")),
            ("Work", .homeChild),
            ("Library/Application Support", .libraryChild),
            ("Library/Preferences", .libraryChild),
        ]
        for expectation in expectations {
            let folder = try expectation.relativePath.isEmpty
                ? home
                : makeFolder(home.appending(path: expectation.relativePath, directoryHint: .isDirectory))
            XCTAssertEqual(
                check(dataPath: folder.path, home: home),
                .failure(expectation.refusal),
                expectation.relativePath
            )
        }
        XCTAssertEqual(check(dataPath: root.path, home: home), .failure(.dataRoot))
    }

    func testShapeRulesOnResolvedComponents() {
        let home = ["Users", "test"]
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "test", "Work", "Notes"], home: home))
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "test", "Library", "Application Support", "App Duplicator", "notes"], home: home))
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["Users", "Jose\u{301}", "Work", "Notes"], home: ["Users", "Jos\u{E9}"]))
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "other", "Work", "Notes"], home: home), .outsideHome)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users"], home: home), .outsideHome)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "TEST"], home: home), .home)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "applications"], home: home), .protectedFolder("Applications"))
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "library", "caches"], home: home), .libraryChild)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["Users", "test", "Library", "Application Support", "app duplicator"], home: home), .dataRoot)
        XCTAssertEqual(EraseOnQuitPolicy.checkShape(["u", "x", "y"], home: ["u"]), .tooShallow)
        XCTAssertNil(EraseOnQuitPolicy.checkShape(["u", "x", "y", "z"], home: ["u"]))
    }

    func testEveryRefusalHasADistinctLogReason() {
        let refusals: [EraseOnQuitRefusal] = [
            .malformedPath, .missing, .unreadable(errno: EACCES), .symbolicLink, .notDirectory, .homeUnresolvable,
            .outsideHome, .home, .homeChild, .protectedFolder("Documents"), .libraryChild, .dataRoot, .tooShallow,
            .protectedSubtree("~/Library/CloudStorage"), .ownerMarkerMissing, .ownerMarkerMismatch,
        ]
        XCTAssertEqual(Set(refusals.map(\.logReason)).count, refusals.count)
        XCTAssertEqual(EraseOnQuitRefusal.symbolicLink.logReason, "the path is a symbolic link")
        XCTAssertEqual(EraseOnQuitRefusal.protectedFolder("Documents").logReason, "the folder is ~/Documents")
        XCTAssertEqual(EraseOnQuitRefusal.unreadable(errno: EACCES).logReason, "the path cannot be inspected (errno 13)")
        XCTAssertEqual(
            HelperLogLine.eraseSkipped(EraseOnQuitRefusal.dataRoot.logReason),
            "helper erase skipped: the folder is the App Duplicator data root"
        )
    }
}
