import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class LaunchPlanPreviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        let target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1", in: dir)
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testPreviewMasksSecretsAndCarriesArgsWarningsAndMode() throws {
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.environment = ["API_TOKEN": "abc", "PLAIN": "1"]
        config.arguments = ["--x"]

        let preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)

        XCTAssertTrue(preview.executablePath.hasSuffix("Contents/MacOS/Target"))
        XCTAssertEqual(preview.arguments.last, "--x")
        XCTAssertEqual(preview.maskedEnvironment["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertEqual(preview.maskedEnvironment["PLAIN"], "1")
        XCTAssertEqual(preview.environmentAdditions["API_TOKEN"], SecretMasking.maskedValue)
        XCTAssertNil(preview.environmentAdditions["PATH"], "inherited variables are not additions")
        XCTAssertEqual(preview.launchMode, .systemLaunch, "/bin/ls is a platform binary; the planner forces System Launch")
        XCTAssertFalse(preview.warnings.isEmpty)
    }

    func testPreviewMissingTargetThrows() {
        XCTAssertThrowsError(try LaunchPlanPreview.make(config: makeConfig(targetPath: dir.appending(path: "Nope.app").path), bundleURL: nil))
    }

    func testPreviewMasksSecretArgumentValues() throws {
        var config = makeConfig(targetPath: dir.appending(path: "Target.app").path)
        config.arguments = ["--api-key", "hunter2", "--token=not-a-real-token", "--plain", "visible"]

        let preview = try LaunchPlanPreview.make(config: config, bundleURL: nil)

        // The /bin/ls stand-in is a native app, so the planner adds no arguments of its own.
        XCTAssertEqual(preview.arguments, ["--api-key", "••••••", "--token=••••••", "--plain", "visible"])
    }
}
