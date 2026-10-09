import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LogReaderTests: XCTestCase {
    func testTailReturnsLastLinesOfExistingLogAndEmptyForMissing() throws {
        let name = "mad-test-\(UUID().uuidString)"
        let logger = LaunchLogger(name: name)
        defer { try? FileManager.default.removeItem(at: logger.fileURL) }
        for i in 1...5 { logger.log("line \(i)") }

        let tail = LogReader.tail(name: name, lines: 2)
        XCTAssertEqual(tail.count, 2)
        XCTAssertTrue(tail[1].hasSuffix("line 5"))
        XCTAssertEqual(LogReader.tail(name: "mad-never-\(UUID().uuidString)"), [])
        XCTAssertEqual(LogReader.logFolder(), logger.fileURL.deletingLastPathComponent())
    }
}
