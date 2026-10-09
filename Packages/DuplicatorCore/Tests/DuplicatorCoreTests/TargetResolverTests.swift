import XCTest
@testable import DuplicatorCore

final class TargetResolverTests: XCTestCase {
    private func config(targetPath: String, bundleID: String) -> ShortcutConfig {
        ShortcutConfig(
            name: "Target Work",
            slug: "target-work",
            bundleIdentifier: "com.mikekuta.appduplicator.target-work",
            targetPath: targetPath,
            targetBundleIdentifier: bundleID
        )
    }

    func testStoredPathWinsWhenTheBundleIdentifierMatches() throws {
        let directory = try makeTemporaryDirectory()
        let bundle = try FixtureBundle(bundleIdentifier: "com.example.resolver-match").write(in: directory)
        let resolved = try TargetResolver().resolve(config: config(targetPath: bundle.path, bundleID: "com.example.resolver-match"))
        XCTAssertEqual(resolved.path, bundle.path)
    }

    func testMismatchedBundleIdentifierWithNoInstalledAppThrowsTargetNotFound() throws {
        let directory = try makeTemporaryDirectory()
        let bundle = try FixtureBundle(bundleIdentifier: "com.example.someone-else").write(in: directory)
        let bundleID = "com.example.mad-not-installed-\(UUID().uuidString)"
        XCTAssertThrowsError(try TargetResolver().resolve(config: config(targetPath: bundle.path, bundleID: bundleID))) { error in
            guard case LauncherError.targetNotFound(let path, let reportedID) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, bundle.path)
            XCTAssertEqual(reportedID, bundleID)
        }
    }

    func testMissingStoredPathFallsBackToLaunchServices() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/System/Applications/TextEdit.app"), "TextEdit is not installed")
        let resolved = try TargetResolver().resolve(config: config(targetPath: "/nonexistent/TextEdit.app", bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(resolved.lastPathComponent, "TextEdit.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.appending(path: "Contents/Info.plist").path))
    }
}
