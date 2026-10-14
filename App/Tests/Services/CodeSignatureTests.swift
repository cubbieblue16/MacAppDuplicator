import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class CodeSignatureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testAdHocSignedBundleReadsAsAdHoc() throws {
        let bundle = try writeShortcutBundle(named: "Signed", in: dir, config: makeConfig(name: "Signed"), withIcon: false)
        let executable = bundle.appending(path: "Contents/MacOS/Signed")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try Signer().sign(bundle: bundle, identity: nil)
        XCTAssertEqual(CodeSignature.of(bundleAt: bundle), .adHoc)
    }

    func testUnsignedOrMissingBundleReadsAsUnknown() throws {
        let bundle = try writeShortcutBundle(named: "Unsigned", in: dir, config: makeConfig(name: "Unsigned"), withIcon: false)
        XCTAssertEqual(CodeSignature.of(bundleAt: bundle), .unknown)
        XCTAssertEqual(CodeSignature.of(bundleAt: dir.appending(path: "Missing.app")), .unknown)
    }

    /// A real ad hoc signed bundle: the empty fixture executable cannot be signed, so `/bin/echo` stands in.
    private func adHocSignedBundle(_ name: String) throws -> URL {
        let bundle = try writeShortcutBundle(named: name, in: dir, config: makeConfig(name: name), withIcon: false)
        let executable = bundle.appending(path: "Contents/MacOS/\(name)")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
        try Signer().sign(bundle: bundle, identity: nil)
        return bundle
    }

    func testVerifyAcceptsAFreshAdHocSignature() throws {
        let bundle = try adHocSignedBundle("Fresh")
        XCTAssertTrue(CodeSignature.verify(bundleAt: bundle, expecting: .adHoc))
    }

    func testVerifyRejectsABundleEditedAfterSigning() throws {
        let bundle = try adHocSignedBundle("Tampered")
        let infoURL = bundle.appending(path: "Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleVersion"] = "999"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        XCTAssertEqual(CodeSignature.of(bundleAt: bundle), .adHoc, "the flags still read as ad hoc; only validity catches the edit")
        XCTAssertFalse(CodeSignature.verify(bundleAt: bundle, expecting: .adHoc))
    }

    func testVerifyRejectsASignerThatIsNotTheExpectedOne() throws {
        let bundle = try adHocSignedBundle("Wrong Signer")
        XCTAssertFalse(CodeSignature.verify(bundleAt: bundle, expecting: .identity("Developer ID Application: Example")))
        XCTAssertFalse(CodeSignature.verify(bundleAt: bundle, expecting: .identity("Quote\" and \\ Backslash")), "escaped names still build a requirement")
        XCTAssertFalse(CodeSignature.verify(bundleAt: bundle, expecting: .unknown))
    }

    func testVerifyRejectsUnsignedAndMissingBundles() throws {
        let unsigned = try writeShortcutBundle(named: "Unsigned Verify", in: dir, config: makeConfig(name: "Unsigned Verify"), withIcon: false)
        XCTAssertFalse(CodeSignature.verify(bundleAt: unsigned, expecting: .adHoc))
        XCTAssertFalse(CodeSignature.verify(bundleAt: dir.appending(path: "Missing.app"), expecting: .adHoc))
    }
}
