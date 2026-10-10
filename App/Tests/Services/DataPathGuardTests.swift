import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Every refusal class of `DataPathGuard` plus the accepted cases, against a fake home inside a temp folder (never the
/// real home, data root or output folder).
final class DataPathGuardTests: XCTestCase {
    private var dir: URL!
    private var home: URL!
    private var dataRoot: URL!
    private var target: URL!
    private var output: URL!
    private var shortcuts: URL!
    private var otherData: URL!
    private var sharedData: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        home = dir.appending(path: "home", directoryHint: .isDirectory)
        dataRoot = home.appending(path: "Library/Application Support/App Duplicator", directoryHint: .isDirectory)
        target = dir.appending(path: "Apps/Target.app", directoryHint: .isDirectory)
        output = home.appending(path: "Applications/App Duplicator", directoryHint: .isDirectory)
        shortcuts = dir.appending(path: "Volumes/Shortcuts", directoryHint: .isDirectory)
        otherData = dataRoot.appending(path: "other", directoryHint: .isDirectory)
        sharedData = dir.appending(path: "Data/shared/inner", directoryHint: .isDirectory)
        for folder in [dataRoot, target, output, shortcuts, otherData, sharedData, home.appending(path: "Documents")] {
            try FileManager.default.createDirectory(at: try XCTUnwrap(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func validate(_ path: String) -> Result<URL, DataPathGuardError> {
        DataPathGuard.validate(
            dataPath: path, targetPath: target.path, outputFolder: output, libraryFolders: [shortcuts],
            otherRecordDataPaths: [otherData.path, sharedData.path], home: home
        )
    }

    private func assertRefused(_ path: String, as kind: String, file: StaticString = #filePath, line: UInt = #line) {
        switch validate(path) {
        case .success(let url): XCTFail("\(path) was accepted as \(url.path)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error.kind, kind, "\(path): \(error.localizedDescription)", file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    private func assertAccepted(_ path: String, resolvingTo expected: String, file: StaticString = #filePath, line: UInt = #line) {
        switch validate(path) {
        case .failure(let error): XCTFail("\(path) was refused: \(error.localizedDescription)", file: file, line: line)
        case .success(let url): XCTAssertEqual(url.path, expected, file: file, line: line)
        }
    }

    /// `realpath(3)`, which keeps `/private` (URL.resolvingSymlinksInPath() strips it).
    private func realPath(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testRefusesEmptyAndRelativePaths() {
        assertRefused("", as: "empty")
        assertRefused("   ", as: "empty")
        assertRefused("relative/data", as: "relative")
        assertRefused("~/Data", as: "relative")
        assertRefused("./data", as: "relative")
    }

    func testRefusesRootItsChildrenHomeAndEveryAncestorOfHome() throws {
        assertRefused("/", as: "protectedLocation")
        assertRefused("/Applications", as: "protectedLocation")
        assertRefused("/private", as: "protectedLocation")
        assertRefused(home.path, as: "protectedLocation")
        assertRefused(home.path + "/", as: "protectedLocation")
        assertRefused(home.appending(path: "Documents/..").path, as: "protectedLocation")
        assertRefused(dir.path, as: "protectedLocation")
        assertRefused(dir.deletingLastPathComponent().path, as: "protectedLocation")
        let link = dir.appending(path: "link-to-home")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        assertRefused(link.path, as: "protectedLocation")
    }

    func testRefusesLibraryAndItsDirectChildren() {
        assertRefused(home.appending(path: "Library").path, as: "protectedLocation")
        assertRefused(home.appending(path: "Library/Preferences").path, as: "protectedLocation")
        assertRefused(home.appending(path: "Library/Application Support").path, as: "protectedLocation")
        assertRefused(home.appending(path: "library/caches").path, as: "protectedLocation")
    }

    func testRefusesTopLevelHomeFolders() throws {
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "desktop"] {
            assertRefused(home.appending(path: name).path, as: "protectedLocation")
        }
        let link = dir.appending(path: "link-to-documents")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Documents"))
        assertRefused(link.path, as: "protectedLocation")
    }

    func testRefusesTheDataRootItself() {
        assertRefused(dataRoot.path, as: "dataRoot")
        assertRefused(dataRoot.path + "/", as: "dataRoot")
    }

    func testRefusesTargetPathsInsideItAndFoldersContainingIt() {
        assertRefused(target.path, as: "overlapsTarget")
        assertRefused(target.appending(path: "Contents/Data").path, as: "overlapsTarget")
        assertRefused(target.deletingLastPathComponent().path, as: "overlapsTarget")
    }

    func testRefusesOutputAndLibraryFoldersAndFoldersContainingThem() {
        assertRefused(output.path, as: "overlapsLibraryFolder")
        assertRefused(home.appending(path: "Applications").path, as: "overlapsLibraryFolder")
        assertRefused(shortcuts.path, as: "overlapsLibraryFolder")
        assertRefused(shortcuts.deletingLastPathComponent().path, as: "overlapsLibraryFolder")
    }

    func testRefusesAnotherShortcutsDataFolderInsideOrAroundIt() {
        assertRefused(otherData.path, as: "usedByAnotherShortcut")
        assertRefused(otherData.appending(path: "nested").path, as: "usedByAnotherShortcut")
        assertRefused(sharedData.path, as: "usedByAnotherShortcut")
        assertRefused(sharedData.deletingLastPathComponent().path, as: "usedByAnotherShortcut")
    }

    func testAcceptsOwnFoldersAndReturnsTheResolvedLocation() throws {
        // A folder that does not exist yet resolves through its nearest existing ancestor.
        assertAccepted(dataRoot.appending(path: "work").path, resolvingTo: try realPath(dataRoot) + "/work")
        let custom = dir.appending(path: "Data/mine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        assertAccepted(custom.path, resolvingTo: try realPath(custom))
        let link = dir.appending(path: "link-to-mine")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: custom)
        assertAccepted(link.path, resolvingTo: try realPath(custom))
        // An empty target path (a record whose target was never set) skips only the target check.
        let noTarget = DataPathGuard.validate(dataPath: custom.path, targetPath: "", outputFolder: output, libraryFolders: [], otherRecordDataPaths: [], home: home)
        XCTAssertEqual(try noTarget.get().path, try realPath(custom))
    }
}

private extension DataPathGuardError {
    var kind: String {
        switch self {
        case .empty: "empty"
        case .relative: "relative"
        case .protectedLocation: "protectedLocation"
        case .dataRoot: "dataRoot"
        case .overlapsTarget: "overlapsTarget"
        case .overlapsLibraryFolder: "overlapsLibraryFolder"
        case .usedByAnotherShortcut: "usedByAnotherShortcut"
        }
    }
}
