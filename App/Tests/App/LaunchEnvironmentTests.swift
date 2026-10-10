import XCTest
@testable import MacAppDuplicator

/// The app's launch-time choices when it hosts the unit tests (final review M15). Uses a unique suite per test, never
/// `LaunchEnvironment.testHostSuiteName` (the running host's suite) or the real preferences.
final class LaunchEnvironmentTests: XCTestCase {
    private var suite: String!

    override func setUpWithError() throws {
        suite = "com.mikekuta.MacAppDuplicatorTests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testDetectsTheXCTestHost() {
        XCTAssertTrue(LaunchEnvironment.isTestHost(["XCTestConfigurationFilePath": "/tmp/run.xctestconfiguration"]))
        XCTAssertFalse(LaunchEnvironment.isTestHost(["HOME": "/Users/test"]))
        XCTAssertTrue(LaunchEnvironment.isTestHost(), "these tests run inside the app as the XCTest host")
    }

    func testTestHostGetsAnEmptiedThrowawaySuite() throws {
        let seeded = try XCTUnwrap(UserDefaults(suiteName: suite))
        seeded.set("/stale/output", forKey: "outputFolderPath")

        let defaults = LaunchEnvironment.settingsDefaults(isTestHost: true, suiteName: suite)
        XCTAssertNil(defaults.string(forKey: "outputFolderPath"), "values left by an earlier run are cleared")

        defaults.set("Ad-hoc", forKey: "signingIdentity")
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: "signingIdentity"), "Ad-hoc", "writes land in the throwaway suite")
    }

    func testTestHostSuiteIsNotTheAppDomain() {
        // `UserDefaults(suiteName:)` returns nil for the main bundle's own identifier.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.mikekuta.MacAppDuplicator")
        XCTAssertNotEqual(LaunchEnvironment.testHostSuiteName, Bundle.main.bundleIdentifier)
    }
}
