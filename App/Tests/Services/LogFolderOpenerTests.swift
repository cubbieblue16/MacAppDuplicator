import XCTest
@testable import MacAppDuplicator

final class LogFolderOpenerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testCreatesTheMissingLogFolder() throws {
        let logs = dir.appending(path: "Logs/App Duplicator", directoryHint: .isDirectory)
        let folder = LogFolderOpener.folderToOpen(reader: LogReader(folder: logs))
        XCTAssertEqual(folder.standardizedFileURL.path, logs.standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFallsBackToTheParentWhenTheFolderCannotBeCreated() throws {
        let parent = dir.appending(path: "Logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocker = parent.appending(path: "App Duplicator")
        try Data().write(to: blocker)  // a file where the log folder should be
        let folder = LogFolderOpener.folderToOpen(reader: LogReader(folder: blocker))
        XCTAssertEqual(folder.standardizedFileURL.path, parent.standardizedFileURL.path)
    }
}
