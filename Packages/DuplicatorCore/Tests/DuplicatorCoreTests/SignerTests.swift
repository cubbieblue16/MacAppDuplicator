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

    func testIdentityArgumentsWithEntitlementsPutThemBeforeTheBundle() {
        let bundle = URL(filePath: "/tmp/Example.app", directoryHint: .isDirectory)
        let entitlements = URL(filePath: "/tmp/mad-entitlements-test.plist", directoryHint: .notDirectory)
        let arguments = Signer.arguments(bundle: bundle, identity: "Developer ID Application: Example", entitlements: entitlements)
        XCTAssertEqual(arguments, [
            "--force", "--sign", "Developer ID Application: Example", "--options", "runtime", "--timestamp",
            "--entitlements", entitlements.path, bundle.path,
        ])
    }

    func testAdHocArgumentsNeverCarryEntitlements() {
        let bundle = URL(filePath: "/tmp/Example.app", directoryHint: .isDirectory)
        let entitlements = URL(filePath: "/tmp/mad-entitlements-test.plist", directoryHint: .notDirectory)
        let arguments = Signer.arguments(bundle: bundle, identity: nil, entitlements: entitlements)
        XCTAssertEqual(arguments, ["--force", "--sign", "-", bundle.path])
        XCTAssertFalse(arguments.contains("--entitlements"))
    }

    func testAppleEventsEntitlementsHoldOnlyTheAutomationKeySetToTrue() throws {
        let plist = try PropertyListSerialization.propertyList(from: Data(Signer.appleEventsEntitlements.utf8), format: nil)
        let dictionary = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual(dictionary.keys.sorted(), ["com.apple.security.automation.apple-events"])
        XCTAssertEqual(dictionary["com.apple.security.automation.apple-events"] as? Bool, true)
    }

    func testEntitlementsFileHoldsTheConstantDuringTheBodyAndIsRemovedAfterwards() throws {
        var seen: URL?
        try Signer.withAppleEventsEntitlementsFile { entitlements in
            seen = entitlements
            XCTAssertEqual(entitlements.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlements), format: nil)
            XCTAssertEqual((plist as? [String: Any])?["com.apple.security.automation.apple-events"] as? Bool, true)
        }
        let file = try XCTUnwrap(seen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testEntitlementsFileIsRemovedWhenTheBodyThrows() throws {
        var seen: URL?
        XCTAssertThrowsError(try Signer.withAppleEventsEntitlementsFile { entitlements in
            seen = entitlements
            throw FixtureError(description: "codesign failed")
        }) { error in
            XCTAssertEqual((error as? FixtureError)?.description, "codesign failed")
        }
        let file = try XCTUnwrap(seen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAdHocSigningIgnoresNeedsAppleEvents() throws {
        let bundle = try makeShortcutBundle()
        try Signer().sign(bundle: bundle, identity: nil, needsAppleEvents: true)

        let verify = try runCommand("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        XCTAssertEqual(verify.status, 0, verify.output)
        let entitlements = try runCommand("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path])
        XCTAssertEqual(entitlements.status, 0, entitlements.output)
        XCTAssertFalse(entitlements.output.contains("com.apple.security.automation.apple-events"), entitlements.output)
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
