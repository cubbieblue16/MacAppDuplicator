import CompatProfiles
import XCTest
@testable import MacAppDuplicator

final class SmokeTests: XCTestCase {
    func testEmbeddedLauncherIsPresentAndSigned() throws {
        let launcher = try EmbeddedLauncher.url()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", launcher.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "embedded Launcher must carry a valid signature")
    }

    func testBundleIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.mikekuta.MacAppDuplicator")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "macOS App Duplicator")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "26.0")
    }

    func testBundledProfilesSeedIsPresentAndValid() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "profiles", withExtension: "json"),
                                "App/project.yml copies Packages/CompatProfiles/Resources/profiles.json into the app")
        let document = try ProfilesDocument.decodeValidated(from: Data(contentsOf: url))
        XCTAssertEqual(document.apps.count, 18)
        XCTAssertEqual(document.apps["com.anthropic.claudefordesktop"]?.status, .verified)
    }
}
