import XCTest
@testable import DuplicatorCore

final class LaunchLoggerTests: XCTestCase {
    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testDefaultLocationAndRotationThreshold() {
        let logger = LaunchLogger(name: "Claude Work")
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/App Duplicator/Claude Work.log")
        XCTAssertEqual(logger.fileURL.path, expected.path)
        XCTAssertEqual(logger.rotatedFileURL.lastPathComponent, "Claude Work.log.1")
        XCTAssertEqual(LaunchLogger.rotationThreshold, 1_048_576)
    }

    func testFileNameUsesTheFileSystemName() throws {
        let logger = LaunchLogger(name: "Work/Personal", directory: try makeTemporaryDirectory(), maxBytes: 1_000)
        XCTAssertEqual(logger.fileURL.lastPathComponent, "Work-Personal.log")
    }

    func testAppendsTimestampedLinesAndCreatesTheDirectory() throws {
        let directory = try makeTemporaryDirectory().appending(path: "Logs/App Duplicator", directoryHint: .isDirectory)
        let logger = LaunchLogger(name: "Claude Work", directory: directory, maxBytes: 1_000)
        logger.log("first")
        logger.log("second")
        let written = try lines(of: logger.fileURL)
        XCTAssertEqual(written.count, 2)
        XCTAssertNotNil(written[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z first$"#, options: .regularExpression), written[0])
        XCTAssertTrue(written[1].hasSuffix("Z second"), written[1])
    }

    func testRotatesToDotOneWhenTheNextLineWouldExceedTheLimit() throws {
        let logger = LaunchLogger(name: "Rotating", directory: try makeTemporaryDirectory(), maxBytes: 100)
        let line = String(repeating: "a", count: 60)
        logger.log("1" + line)
        logger.log("2" + line)
        XCTAssertEqual(try lines(of: logger.rotatedFileURL).count, 1)
        XCTAssertTrue(try lines(of: logger.rotatedFileURL)[0].hasSuffix("1" + line))
        XCTAssertEqual(try lines(of: logger.fileURL).count, 1)
        XCTAssertTrue(try lines(of: logger.fileURL)[0].hasSuffix("2" + line))

        logger.log("3" + line)
        XCTAssertTrue(try lines(of: logger.rotatedFileURL)[0].hasSuffix("2" + line))
        XCTAssertTrue(try lines(of: logger.fileURL)[0].hasSuffix("3" + line))
    }

    func testEnvironmentIsLoggedSortedAndMasked() throws {
        let logger = LaunchLogger(name: "Env", directory: try makeTemporaryDirectory(), maxBytes: 10_000)
        logger.log(environment: ["Z_PLAIN": "visible", "API_TOKEN": "not-a-real-token", "db_password": "hunter2"])
        let written = try lines(of: logger.fileURL).map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        XCTAssertEqual(written, ["env API_TOKEN=••••••", "env Z_PLAIN=visible", "env db_password=••••••"])
        let raw = try String(contentsOf: logger.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("not-a-real-token"))
        XCTAssertFalse(raw.contains("hunter2"))
    }
}
