@testable import DuplicatorCore
import Foundation
import XCTest

extension XCTestCase {
    /// A fresh directory under the system temporary directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WebShellTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        return directory
    }

    /// A LaunchLogger that writes into a temporary directory, never `~/Library/Logs/App Duplicator`.
    func makeTemporaryLogger() throws -> LaunchLogger {
        LaunchLogger(name: "WebShellTests", directory: try makeTemporaryDirectory(), maxBytes: LaunchLogger.rotationThreshold)
    }

    /// Logged lines with the leading ISO 8601 timestamp removed.
    func loggedMessages(_ logger: LaunchLogger) throws -> [String] {
        guard FileManager.default.fileExists(atPath: logger.fileURL.path) else { return [] }
        return try String(contentsOf: logger.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                guard let space = line.firstIndex(of: " ") else { return String(line) }
                return String(line[line.index(after: space)...])
            }
    }
}
