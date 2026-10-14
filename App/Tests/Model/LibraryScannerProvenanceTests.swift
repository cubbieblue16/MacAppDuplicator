import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

/// Security C3: a bundle carrying `MADConfig` is only data, so the scanner marks every bundle this install did not write
/// as foreign. The app then never regenerates and re-signs one with the user's identity before the user reviews it.
final class LibraryScannerProvenanceTests: XCTestCase {
    private var dir: URL!
    private let token = String(repeating: "ab", count: 32)
    private let developerID = CodeSignature.identity("Developer ID Application: Test (TEAMID)")

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func bundle(_ name: String, stamped: Any? = nil) throws -> URL {
        try writeShortcutBundle(
            named: name, in: dir, config: makeConfig(name: name), withIcon: false,
            extraInfo: stamped.map { [ShortcutConfig.installTokenInfoPlistKey: $0] } ?? [:]
        )
    }

    private func info(_ bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func provenance(
        _ bundle: URL, installToken: String?, expected: CodeSignature?, signature: ((URL) -> CodeSignature)? = nil
    ) throws -> ShortcutRecord.Provenance {
        let info = try info(bundle)
        if let signature {
            return LibraryScanner.provenance(infoPlist: info, bundleURL: bundle, installToken: installToken, expectedSignature: expected, signature: signature)
        }
        return LibraryScanner.provenance(infoPlist: info, bundleURL: bundle, installToken: installToken, expectedSignature: expected)
    }

    /// A real ad hoc signature, as `CodeSignatureTests` makes one: the empty fixture executable cannot be signed.
    private func adHocSign(_ bundle: URL) throws {
        let executable = bundle.appending(path: "Contents/MacOS/\(bundle.deletingPathExtension().lastPathComponent)")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try Signer().sign(bundle: bundle, identity: nil)
        XCTAssertEqual(CodeSignature.of(bundleAt: bundle), .adHoc)
    }

    /// Sets the flag macOS puts on downloads and received files.
    private func quarantine(_ url: URL) throws {
        let value = Array("0083;00000000;Safari;".utf8)
        let result = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path!, LibraryScanner.quarantineAttribute, value, value.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "setxattr failed: \(String(cString: strerror(errno)))")
        XCTAssertTrue(LibraryScanner.isQuarantined(url.pathExtension == "app" ? url : url.deletingLastPathComponent().deletingLastPathComponent()))
    }

    func testThisInstallsTokenIsOwn() throws {
        let mine = try bundle("Mine", stamped: token)
        XCTAssertEqual(try provenance(mine, installToken: token, expected: developerID), .own, "the token alone vouches, whatever the signature")
    }

    func testQuarantinedBundleIsForeignEvenWithThisInstallsToken() throws {
        let received = try bundle("Received", stamped: token)
        try quarantine(received)
        XCTAssertEqual(try provenance(received, installToken: token, expected: .adHoc), .foreign(reason: "downloaded or received (quarantined)"))

        // A non-recursive `xattr -d` clears only the bundle folder; the flag left on Info.plist still counts.
        let partlyCleared = try bundle("Partly Cleared", stamped: token)
        try quarantine(partlyCleared.appending(path: "Contents/Info.plist"))
        XCTAssertEqual(try provenance(partlyCleared, installToken: token, expected: .adHoc), .foreign(reason: "downloaded or received (quarantined)"))

        let signed = try bundle("Signed Received")
        try adHocSign(signed)
        try quarantine(signed)
        XCTAssertEqual(try provenance(signed, installToken: token, expected: .adHoc), .foreign(reason: "downloaded or received (quarantined)"),
                       "a quarantined bundle is foreign even when its signature matches")
    }

    func testAnyOtherTokenIsForeign() throws {
        let different = "built by a different App Duplicator install"
        let other = try bundle("Other", stamped: String(repeating: "cd", count: 32))
        try adHocSign(other)
        XCTAssertEqual(try provenance(other, installToken: token, expected: .adHoc), .foreign(reason: different),
                       "a foreign token is not rescued by a matching signature")
        XCTAssertEqual(try provenance(try bundle("Number", stamped: 42), installToken: token, expected: .adHoc), .foreign(reason: different))
        XCTAssertEqual(try provenance(try bundle("No Install Token", stamped: token), installToken: nil, expected: .adHoc), .foreign(reason: different))
        XCTAssertEqual(try provenance(try bundle("Empty", stamped: ""), installToken: "", expected: .adHoc), .foreign(reason: different),
                       "an empty token never matches")
    }

    func testTokenlessBundleIsOwnOnlyWhenSignedLikeTheConfiguredIdentity() throws {
        let adHoc = try bundle("Legacy Ad Hoc")
        try adHocSign(adHoc)
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: .adHoc), .own)
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: developerID), .foreign(reason: "signed ad hoc, not by your signing identity"))
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: nil), .foreign(reason: "signed ad hoc, not by your signing identity"))

        let unsigned = try bundle("Unsigned")
        XCTAssertEqual(try provenance(unsigned, installToken: token, expected: .adHoc), .foreign(reason: "unsigned"))
        XCTAssertEqual(try provenance(unsigned, installToken: token, expected: .unknown), .foreign(reason: "unsigned"), "unsigned is never own")

        // No test can sign with a Developer ID, so the signature reader is injected for the certificate cases.
        let legacy = try bundle("Legacy Developer ID")
        XCTAssertEqual(try provenance(legacy, installToken: token, expected: developerID, signature: { _ in self.developerID }), .own)
        XCTAssertEqual(
            try provenance(legacy, installToken: token, expected: developerID, signature: { _ in .identity("Developer ID Application: Mallory (EVIL)") }),
            .foreign(reason: "signed by Developer ID Application: Mallory (EVIL)")
        )
        XCTAssertEqual(try provenance(legacy, installToken: token, expected: .adHoc, signature: { _ in self.developerID }),
                       .foreign(reason: "signed by Developer ID Application: Test (TEAMID)"))
    }

    func testScanAndRecordCarryProvenanceAndTheDefaultTrustsNothing() throws {
        let mine = try bundle("Mine", stamped: token)
        let planted = try bundle("Planted")
        let trust = ScanTrust(installToken: token, expectedSignature: .adHoc)

        let records = LibraryScanner().scan(folders: [dir], trust: trust).records
        XCTAssertEqual(records.map(\.name), ["Mine", "Planted"])
        XCTAssertEqual(records.map(\.provenance), [.own, .foreign(reason: "unsigned")])
        XCTAssertEqual(records.map(\.isForeign), [false, true])
        XCTAssertEqual(records.map(\.foreignReason), [nil, "unsigned"])

        XCTAssertTrue(LibraryScanner().scan(folders: [dir]).records.allSatisfy(\.isForeign), "without trust every bundle is foreign")
        XCTAssertTrue(try LibraryScanner.record(forBundleAt: mine).isForeign)
        XCTAssertFalse(try LibraryScanner.record(forBundleAt: mine, trust: trust).isForeign)
        XCTAssertTrue(try LibraryScanner.record(forBundleAt: planted, trust: trust).isForeign)
    }
}
