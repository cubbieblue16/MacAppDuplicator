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
        _ bundle: URL, installToken: String?, expected: CodeSignature?,
        signature: ((URL) -> CodeSignature)? = nil, verify: ((URL, CodeSignature) -> Bool)? = nil
    ) throws -> ShortcutRecord.Provenance {
        let info = try info(bundle)
        let read = signature ?? { CodeSignature.of(bundleAt: $0) }
        let check = verify ?? { CodeSignature.verify(bundleAt: $0, expecting: $1) }
        return LibraryScanner.provenance(
            infoPlist: info, bundleURL: bundle, installToken: installToken, expectedSignature: expected, signature: read, verify: check
        )
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

    func testThisInstallsTokenIsOwnOnlyWhenTheSignatureVerifies() throws {
        let mine = try bundle("Mine", stamped: token)
        XCTAssertEqual(try provenance(mine, installToken: token, expected: .adHoc, verify: { _, _ in true }), .own)

        let changed = "changed since this App Duplicator built it (its signature does not verify)"
        XCTAssertEqual(try provenance(mine, installToken: token, expected: .adHoc, verify: { _, _ in false }), .foreign(reason: changed))
        XCTAssertEqual(try provenance(mine, installToken: token, expected: nil, verify: { _, _ in true }), .foreign(reason: changed),
                       "with no expected signature there is nothing to verify against")
        XCTAssertEqual(try provenance(mine, installToken: token, expected: developerID, verify: { _, expected in expected == self.developerID }), .own,
                       "verify receives the expected signature")
    }

    func testStolenTokenOnAnEditedBundleIsForeign() throws {
        let edited = try bundle("Edited", stamped: token)
        try adHocSign(edited)
        let infoURL = edited.appending(path: "Contents/Info.plist")
        var plist = try info(edited)
        plist["CFBundleVersion"] = "999"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: infoURL)
        guard case .foreign(let reason) = try provenance(edited, installToken: token, expected: .adHoc) else {
            return XCTFail("an edited bundle must not read as own")
        }
        XCTAssertTrue(reason.contains("does not verify"), reason)
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

    func testTokenlessBundleIsNeverOwnUnderAdHocSigning() throws {
        let adHoc = try bundle("Legacy Ad Hoc")
        try adHocSign(adHoc)
        let reason = "no install token; an ad hoc signature cannot show who built it"
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: .adHoc), .foreign(reason: reason),
                       "anyone can ad hoc sign, so a valid ad hoc signature does not vouch for a tokenless bundle")
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: .adHoc, verify: { _, _ in true }), .foreign(reason: reason))
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: nil, verify: { _, _ in true }), .foreign(reason: reason))
        XCTAssertEqual(try provenance(adHoc, installToken: token, expected: developerID), .foreign(reason: "signed ad hoc, not by your signing identity"))

        let unsigned = try bundle("Unsigned")
        XCTAssertEqual(try provenance(unsigned, installToken: token, expected: developerID), .foreign(reason: "unsigned"))
        XCTAssertEqual(try provenance(unsigned, installToken: token, expected: .unknown), .foreign(reason: "unsigned"), "unsigned is never own")
    }

    func testTokenlessBundleIsOwnOnlyUnderAVerifiedIdentitySignature() throws {
        // No test can sign with a Developer ID, so the signature reader and verifier are injected.
        let legacy = try bundle("Legacy Developer ID")
        XCTAssertEqual(try provenance(legacy, installToken: token, expected: developerID, signature: { _ in self.developerID }, verify: { _, _ in true }), .own)
        XCTAssertEqual(
            try provenance(legacy, installToken: token, expected: developerID, signature: { _ in .identity("Other") }, verify: { _, _ in false }),
            .foreign(reason: "signed by Other")
        )
        XCTAssertEqual(
            try provenance(legacy, installToken: token, expected: developerID, signature: { _ in self.developerID }, verify: { _, _ in false }),
            .foreign(reason: "signed as Developer ID Application: Test (TEAMID) but the signature does not verify"),
            "a matching name that does not verify (a self-made certificate, or an edited bundle) is not own"
        )
        XCTAssertEqual(try provenance(legacy, installToken: token, expected: developerID, signature: { _ in .unknown }, verify: { _, _ in false }), .foreign(reason: "unsigned"))
    }

    func testScanAndRecordCarryProvenanceAndTheDefaultTrustsNothing() throws {
        let mine = try bundle("Mine", stamped: token)
        try adHocSign(mine)
        let planted = try bundle("Planted")
        let plantedReason = "no install token; an ad hoc signature cannot show who built it"
        let trust = ScanTrust(installToken: token, expectedSignature: .adHoc)

        let records = LibraryScanner().scan(folders: [dir], trust: trust).records
        XCTAssertEqual(records.map(\.name), ["Mine", "Planted"])
        XCTAssertEqual(records.map(\.provenance), [.own, .foreign(reason: plantedReason)])
        XCTAssertEqual(records.map(\.isForeign), [false, true])
        XCTAssertEqual(records.map(\.foreignReason), [nil, plantedReason])

        XCTAssertTrue(LibraryScanner().scan(folders: [dir]).records.allSatisfy(\.isForeign), "without trust every bundle is foreign")
        XCTAssertTrue(try LibraryScanner.record(forBundleAt: mine).isForeign)
        XCTAssertFalse(try LibraryScanner.record(forBundleAt: mine, trust: trust).isForeign)
        XCTAssertTrue(try LibraryScanner.record(forBundleAt: planted, trust: trust).isForeign)
    }

    // MARK: Legacy candidates: tokenless ad hoc bundles from before 0.8.0 get one aggregate review

    /// Runs the candidate rule on the provenance this install would compute (`installToken` is `token`).
    private func isLegacyCandidate(
        _ bundle: URL, expected: CodeSignature? = .adHoc,
        signature: ((URL) -> CodeSignature)? = nil, verify: ((URL, CodeSignature) -> Bool)? = nil
    ) throws -> Bool {
        let provenance = try provenance(bundle, installToken: token, expected: expected, signature: signature, verify: verify)
        let read = signature ?? { CodeSignature.of(bundleAt: $0) }
        return LibraryScanner.isLegacyCandidate(provenance: provenance, infoPlist: try info(bundle), bundleURL: bundle, signature: read)
    }

    func testTokenlessAdHocUnquarantinedBundleIsALegacyCandidate() throws {
        let legacy = try bundle("Legacy")
        try adHocSign(legacy)
        XCTAssertTrue(try isLegacyCandidate(legacy))
        XCTAssertTrue(try isLegacyCandidate(legacy, expected: nil), "with no expected signature it is still foreign")
        XCTAssertTrue(try isLegacyCandidate(legacy, expected: developerID),
                      "switching to a Developer ID leaves shortcuts built before 0.8.0 tokenless and ad hoc")

        let record = try LibraryScanner.record(forBundleAt: legacy, trust: ScanTrust(installToken: token, expectedSignature: .adHoc))
        XCTAssertTrue(record.isLegacyCandidate, "the scanner decides it")
        XCTAssertTrue(record.isForeign, "a candidate stays foreign until the user trusts it")
        XCTAssertEqual(record.foreignReason, "no install token; an ad hoc signature cannot show who built it")
    }

    func testQuarantinedBundleIsNotALegacyCandidate() throws {
        let received = try bundle("Received")
        try adHocSign(received)
        try quarantine(received)
        XCTAssertFalse(try isLegacyCandidate(received))

        let partlyCleared = try bundle("Partly Cleared")
        try adHocSign(partlyCleared)
        try quarantine(partlyCleared.appending(path: "Contents/Info.plist"))
        XCTAssertFalse(try isLegacyCandidate(partlyCleared), "a flag left on Info.plist still counts")
    }

    func testAnyInstallTokenKeyRulesOutALegacyCandidate() throws {
        let other = try bundle("Other", stamped: String(repeating: "cd", count: 32))
        try adHocSign(other)
        XCTAssertEqual(try provenance(other, installToken: token, expected: .adHoc), .foreign(reason: "built by a different App Duplicator install"))
        XCTAssertFalse(try isLegacyCandidate(other), "another install's token")

        let empty = try bundle("Empty", stamped: "")
        try adHocSign(empty)
        XCTAssertFalse(try isLegacyCandidate(empty), "an empty token is still a key")

        let changed = try bundle("Changed", stamped: token)
        try adHocSign(changed)
        XCTAssertEqual(
            try provenance(changed, installToken: token, expected: .adHoc, verify: { _, _ in false }),
            .foreign(reason: "changed since this App Duplicator built it (its signature does not verify)")
        )
        XCTAssertFalse(try isLegacyCandidate(changed, verify: { _, _ in false }), "this install's token on a bundle that does not verify")
    }

    func testTokenlessBundleNotSignedAdHocIsNotALegacyCandidate() throws {
        // No test can sign with a Developer ID, so the signature reader and verifier are injected.
        let certificate = try bundle("Certificate")
        XCTAssertFalse(try isLegacyCandidate(certificate, expected: developerID, signature: { _ in self.developerID }, verify: { _, _ in false }),
                       "a certificate signature that does not verify")
        XCTAssertFalse(try isLegacyCandidate(certificate, expected: .adHoc, signature: { _ in .identity("Other") }), "signed by someone else")

        let unsigned = try bundle("Unsigned")
        XCTAssertEqual(CodeSignature.of(bundleAt: unsigned), .unknown)
        XCTAssertFalse(try isLegacyCandidate(unsigned), "unsigned")
        XCTAssertFalse(try isLegacyCandidate(unsigned, expected: developerID), "unsigned")
    }

    func testOwnBundleIsNeverALegacyCandidate() throws {
        let mine = try bundle("Mine", stamped: token)
        try adHocSign(mine)
        XCTAssertEqual(try provenance(mine, installToken: token, expected: .adHoc), .own)
        XCTAssertFalse(try isLegacyCandidate(mine))

        let legacy = try bundle("Legacy Developer ID")
        XCTAssertFalse(LibraryScanner.isLegacyCandidate(provenance: .own, infoPlist: try info(legacy), bundleURL: legacy, signature: { _ in .adHoc }),
                       "own is never a candidate, even tokenless and ad hoc")
    }

    func testScanMarksOnlyLegacyCandidates() throws {
        try adHocSign(try bundle("Legacy"))
        try adHocSign(try bundle("Mine", stamped: token))
        _ = try bundle("Unsigned")
        let records = LibraryScanner().scan(folders: [dir], trust: ScanTrust(installToken: token, expectedSignature: .adHoc)).records
        XCTAssertEqual(records.map(\.name), ["Legacy", "Mine", "Unsigned"])
        XCTAssertEqual(records.map(\.isLegacyCandidate), [true, false, false])
        XCTAssertEqual(records.map(\.isForeign), [true, false, true])
    }
}
