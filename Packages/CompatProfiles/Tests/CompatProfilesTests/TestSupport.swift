import Foundation
import XCTest
@testable import CompatProfiles

extension XCTestCase {
    /// A new empty directory under the system temporary directory, deleted when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CompatProfilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// JSON bytes for a hand-built object (sorted keys, so failures are reproducible).
func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// `profiles.json` bytes built from plain values, so each test varies only the fields it is about.
func makeProfilesData(schemaVersion: Any = 1, updated: Any = "2026-10-09", apps: [String: Any] = [:],
                      webApps: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["schemaVersion": schemaVersion, "updated": updated, "apps": apps]
    if let webApps { object["webApps"] = webApps }
    object.merge(extra) { _, new in new }
    return try jsonData(object)
}

/// The smallest valid `apps` entry, plus `extra` fields.
func appEntry(name: String = "Example", status: String = "partial", extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["name": name, "status": status]
    entry.merge(extra) { _, new in new }
    return entry
}

/// The smallest valid `webApps` entry, plus `extra` fields.
func webAppEntry(extra: [String: Any] = [:]) -> [String: Any] {
    var entry: [String: Any] = ["name": "WhatsApp", "url": "https://web.whatsapp.com"]
    entry.merge(extra) { _, new in new }
    return entry
}

/// Asserts that `ProfilesDocument.decodeValidated(from:)` refuses `data` with exactly `expected`.
func assertRejects(_ data: Data, with expected: ProfilesError, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try ProfilesDocument.decodeValidated(from: data), file: file, line: line) { error in
        XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
    }
}

/// Writes `data` to `name` inside `directory` and returns the file URL.
func writeFile(_ data: Data, named name: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try data.write(to: url)
    return url
}
