import XCTest
@testable import DuplicatorCore

final class FileConfigTests: XCTestCase {
    func testInitializerDefaults() {
        let config = FileConfig(path: "/Users/test/Documents/Report.pdf")
        XCTAssertEqual(config.path, "/Users/test/Documents/Report.pdf")
        XCTAssertNil(config.openerAppPath)
    }

    func testNormalizedPathExpandsTildeAndStripsTrailingSlashes() {
        XCTAssertEqual(FileConfig.normalizedPath("~/Documents/Report.pdf"), NSHomeDirectory() + "/Documents/Report.pdf")
        XCTAssertEqual(FileConfig.normalizedPath("~"), NSHomeDirectory())
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/Projects/"), "/Users/test/Projects")
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/Projects///"), "/Users/test/Projects")
        XCTAssertEqual(FileConfig.normalizedPath("/"), "/")
        XCTAssertEqual(FileConfig.normalizedPath(""), "")
    }

    func testNormalizedPathRemovesDotComponentsWithoutTouchingTheFileSystem() {
        XCTAssertEqual(FileConfig.normalizedPath("/Users/test/./Projects/../Notes"), "/Users/test/Notes")
        // A path that does not exist is standardized too, and symlinks such as /tmp are not resolved.
        XCTAssertEqual(FileConfig.normalizedPath("/tmp/mad-does-not-exist/../x"), "/tmp/x")
        XCTAssertEqual(FileConfig.normalizedPath("relative/folder/"), "relative/folder")
    }

    func testCodableRoundTripOmitsANilOpener() throws {
        let plain = FileConfig(path: "/Users/test/Projects")
        let withOpener = FileConfig(path: "/Users/test/Notes.md", openerAppPath: "/Applications/TextEdit.app")
        for config in [plain, withOpener] {
            let data = try PropertyListEncoder().encode(config)
            XCTAssertEqual(try PropertyListDecoder().decode(FileConfig.self, from: data), config)
        }
        let encoded = try PropertyListEncoder().encode(plain)
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        XCTAssertEqual(Set(dictionary.keys), ["path"])
    }
}
