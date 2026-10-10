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
}
