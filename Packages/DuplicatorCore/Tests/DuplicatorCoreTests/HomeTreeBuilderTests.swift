import XCTest
@testable import DuplicatorCore

final class HomeTreeBuilderTests: XCTestCase {
    private let fileManager = FileManager.default

    /// A fake real home holding `Documents/`, `.gitconfig` and `.ssh/` only.
    private func makeRealHome(in sandbox: URL) throws -> URL {
        let realHome = sandbox.appending(path: "real-home", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: realHome.appending(path: "Documents"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realHome.appending(path: ".ssh"), withIntermediateDirectories: true)
        try Data("[user]\n".utf8).write(to: realHome.appending(path: ".gitconfig"))
        return realHome
    }

    private func entries(_ directory: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testEmptyDirectoryGetsTheTreeInPlace() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = try makeRealHome(in: sandbox)
        let target = sandbox.appending(path: "data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        let home = try HomeTreeBuilder(realHome: realHome).materialize(at: target)

        XCTAssertEqual(home.path, target.path)
        XCTAssertEqual(try entries(home), [".gitconfig", ".mad-home-tree", ".ssh", "Documents", "Library"])
        XCTAssertEqual(try entries(home.appending(path: "Library")), HomeTreeBuilder.libraryDirectories.sorted())
        for name in [".gitconfig", ".ssh", "Documents"] {
            XCTAssertEqual(
                try fileManager.destinationOfSymbolicLink(atPath: home.appending(path: name).path),
                realHome.appending(path: name).path,
                name
            )
        }
        for name in HomeTreeBuilder.libraryDirectories {
            var isDirectory: ObjCBool = false
            let path = home.appending(path: "Library").appending(path: name).path
            XCTAssertTrue(fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue, name)
            XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: path), "\(name) must be a real directory")
        }
    }

    func testMissingDirectoryIsCreated() throws {
        let sandbox = try makeTemporaryDirectory()
        let target = sandbox.appending(path: "a/b/data", directoryHint: .isDirectory)
        let home = try HomeTreeBuilder(realHome: try makeRealHome(in: sandbox)).materialize(at: target)
        XCTAssertEqual(home.path, target.path)
        XCTAssertTrue(fileManager.fileExists(atPath: target.appending(path: HomeTreeBuilder.markerFileName).path))
    }

    func testDefaultSymlinkEntriesAreTheSpecList() {
        XCTAssertEqual(HomeTreeBuilder.defaultSymlinkEntries, [
            "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
            ".ssh", ".gitconfig", ".zshrc", ".zshenv", ".zprofile", ".zsh", ".oh-my-zsh",
            ".bashrc", ".bash_profile", ".profile",
            ".config", ".docker", ".npmrc", ".nvm", ".cargo", ".rustup", ".local", ".gnupg",
        ])
        XCTAssertEqual(HomeTreeBuilder.libraryDirectories, [
            "Application Support", "Preferences", "Caches", "Containers", "Group Containers",
            "Saved Application State", "WebKit", "HTTPStorages", "Cookies", "Logs", "Keychains",
        ])
    }

    func testSecondCallIsANoOp() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = try makeRealHome(in: sandbox)
        let target = sandbox.appending(path: "data", directoryHint: .isDirectory)
        let builder = HomeTreeBuilder(realHome: realHome)
        let first = try builder.materialize(at: target)

        // The user removed a symlink to get a private copy (spec §4.3); a later launch must not recreate it.
        try fileManager.removeItem(at: first.appending(path: ".gitconfig"))
        let second = try builder.materialize(at: target)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try entries(second), [".mad-home-tree", ".ssh", "Documents", "Library"])
    }

    func testNonEmptyDirectoryUsesAUserNamedSubfolder() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = try makeRealHome(in: sandbox)
        let target = sandbox.appending(path: "data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "existing.txt"))
        let builder = HomeTreeBuilder(realHome: realHome)

        let home = try builder.materialize(at: target)

        XCTAssertEqual(home.path, target.appending(path: NSUserName()).path)
        XCTAssertEqual(try entries(target).sorted(), [NSUserName(), "existing.txt"].sorted())
        XCTAssertEqual(try String(contentsOf: target.appending(path: "existing.txt"), encoding: .utf8), "keep")
        XCTAssertTrue(fileManager.fileExists(atPath: home.appending(path: HomeTreeBuilder.markerFileName).path))
        XCTAssertEqual(try builder.materialize(at: target), home, "later launches find the subfolder again")
    }

    func testDirectoryHoldingOnlyDSStoreCountsAsEmpty() throws {
        let sandbox = try makeTemporaryDirectory()
        let target = sandbox.appending(path: "data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appending(path: ".DS_Store"))
        let home = try HomeTreeBuilder(realHome: try makeRealHome(in: sandbox)).materialize(at: target)
        XCTAssertEqual(home.path, target.path)
    }

    func testNothingIsWrittenOutsideThePath() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = try makeRealHome(in: sandbox)
        let parent = sandbox.appending(path: "parent", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data().write(to: parent.appending(path: "sibling.txt"))
        let target = parent.appending(path: "data", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let parentBefore = try entries(parent)
        let realHomeBefore = try fileManager.subpathsOfDirectory(atPath: realHome.path).sorted()

        _ = try HomeTreeBuilder(realHome: realHome).materialize(at: target)

        XCTAssertEqual(try entries(parent), parentBefore)
        XCTAssertEqual(try fileManager.subpathsOfDirectory(atPath: realHome.path).sorted(), realHomeBefore)
    }

    func testEntriesThatAreNotASinglePathComponentAreIgnored() throws {
        let sandbox = try makeTemporaryDirectory()
        let realHome = try makeRealHome(in: sandbox)
        try fileManager.createDirectory(at: realHome.appending(path: "a/b"), withIntermediateDirectories: true)
        let target = sandbox.appending(path: "parent/data", directoryHint: .isDirectory)
        let builder = HomeTreeBuilder(realHome: realHome, symlinkEntries: ["../escape", "a/b", ".", "..", "", "Documents"])

        let home = try builder.materialize(at: target)

        XCTAssertEqual(try entries(home), [".mad-home-tree", "Documents", "Library"])
        XCTAssertEqual(try entries(sandbox.appending(path: "parent")), ["data"])
        XCTAssertFalse(HomeTreeBuilder.isPlainEntryName("../escape"))
        XCTAssertTrue(HomeTreeBuilder.isPlainEntryName(".ssh"))
    }
}
