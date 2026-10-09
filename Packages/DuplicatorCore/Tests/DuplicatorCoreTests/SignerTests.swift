import XCTest
@testable import DuplicatorCore

final class SignerTests: XCTestCase {
    private func makeShortcutBundle() throws -> URL {
        let root = try makeTemporaryDirectory()
        let target = try FixtureBundle().write(in: root)
        let app = try AppInspector().inspect(appAt: target)
        let config = ShortcutConfig(
            name: "Signed Shortcut",
            slug: "signed-shortcut",
            bundleIdentifier: "com.mikekuta.appduplicator.signed-shortcut",
            targetPath: target.path,
            targetBundleIdentifier: "com.example.fixture"
        )
        return try BundleWriter().write(config: config, app: app, launcherBinary: URL(filePath: "/usr/bin/true"), to: root.appending(path: "out", directoryHint: .isDirectory))
    }

    func testAdHocSigningProducesValidBundle() throws {
        let bundle = try makeShortcutBundle()
        let before = try runCommand("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        XCTAssertNotEqual(before.status, 0, "an unsigned bundle must not verify; otherwise this test proves nothing")

        try Signer().sign(bundle: bundle, identity: nil)

        let after = try runCommand("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        XCTAssertEqual(after.status, 0, after.output)
    }

    func testAdHocArguments() {
        let bundle = URL(filePath: "/tmp/Example.app", directoryHint: .isDirectory)
        XCTAssertEqual(Signer.arguments(bundle: bundle, identity: nil), ["--force", "--sign", "-", bundle.path])
    }

    func testIdentityArguments() {
        let bundle = URL(filePath: "/tmp/Example.app", directoryHint: .isDirectory)
        let arguments = Signer.arguments(bundle: bundle, identity: "Developer ID Application: Example")
        XCTAssertEqual(arguments, [
            "--force", "--sign", "Developer ID Application: Example", "--options", "runtime", "--timestamp", bundle.path,
        ])
        XCTAssertFalse(arguments.contains("--deep"))
    }

    func testSigningMissingPathThrowsSignerError() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appending(path: "Missing.app", directoryHint: .isDirectory)
        XCTAssertThrowsError(try Signer().sign(bundle: missing, identity: nil)) { error in
            guard let signerError = error as? SignerError else {
                return XCTFail("expected SignerError, got \(error)")
            }
            XCTAssertNotEqual(signerError.status, 0)
            XCTAssertFalse(signerError.message.isEmpty)
        }
    }
}
