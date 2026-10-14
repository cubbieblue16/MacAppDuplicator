import XCTest
@testable import DuplicatorCore

final class BoundedFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "bounded-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ count: Int, name: String = "f.bin") throws -> URL {
        let url = directory.appending(path: name)
        try Data(repeating: 7, count: count).write(to: url)
        return url
    }

    func testReadsAFileWithinTheCap() throws {
        let url = try write(1000)
        XCTAssertEqual(try BoundedFileReader.read(url, maxBytes: 1000).count, 1000)
        XCTAssertEqual(try BoundedFileReader.read(try write(0, name: "empty"), maxBytes: 10), Data())
    }

    func testRefusesAFileOverTheCap() throws {
        let url = try write(1001)
        XCTAssertThrowsError(try BoundedFileReader.read(url, maxBytes: 1000)) { error in
            XCTAssertEqual(error as? BoundedFileReader.TooLarge, BoundedFileReader.TooLarge(path: url.path, maxBytes: 1000))
        }
    }

    func testFollowsSymlinksLikeDataContentsOf() throws {
        let target = try write(10)
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try BoundedFileReader.read(link).count, 10)
    }

    func testDefaultCapIs16MiB() {
        XCTAssertEqual(BoundedFileReader.defaultMaxBytes, 16 * 1024 * 1024)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try BoundedFileReader.read(directory.appending(path: "nope")))
    }
}
