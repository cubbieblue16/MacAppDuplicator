import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Hermetic: logs are written under a temporary folder, never `~/Library/Logs/App Duplicator` (final review M18).
final class LogReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let dir { try FileManager.default.removeItem(at: dir) }
    }

    func testTailReturnsLastLinesOfTheLaunchersLog() {
        let logger = LaunchLogger(name: "Mad Test", directory: dir, maxBytes: LaunchLogger.rotationThreshold)
        for i in 1...5 { logger.log("line \(i)") }

        let reader = LogReader(folder: dir)
        let tail = reader.tail(name: "Mad Test", lines: 2)
        XCTAssertEqual(tail.count, 2)
        XCTAssertTrue(tail[1].hasSuffix("line 5"))
        XCTAssertEqual(reader.tail(name: "Mad Test").count, 5, "the default line limit covers a short log")
        XCTAssertEqual(reader.logFolder(), dir)
    }

    func testTailIsEmptyWhenThereIsNoLog() {
        XCTAssertEqual(LogReader(folder: dir).tail(name: "Never Logged"), [])
    }

    func testDefaultFolderIsTheLaunchersLogFolder() {
        // Path only: `LaunchLogger(name:)` builds the URL and writes nothing until `log` is called.
        let expected = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/App Duplicator", directoryHint: .isDirectory)
        XCTAssertEqual(LogReader().logFolder().standardizedFileURL.path, expected.standardizedFileURL.path)
    }
}
