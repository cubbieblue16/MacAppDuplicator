import XCTest
@testable import MacAppDuplicator

final class SigningIdentitiesTests: XCTestCase {
    private let sample = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)"
      2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Apple Development: 152761714+cubbieblue16.noreply.github.com (GZHS2TWCRJ)"
      3) 89ABCDEF0123456789ABCDEF0123456789ABCDE0 "Apple Development: 152761714+cubbieblue16.noreply.github.com (GZHS2TWCRJ)" (CSSMERR_TP_CERT_REVOKED)
      4) FEDCBA9876543210FEDCBA9876543210FEDCBA98 "Apple Development: 152761714+cubbieblue16.noreply.github.com (GZHS2TWCRJ)"
         3 valid identities found
    """

    func testParseKeepsValidUniqueNamesInOrder() {
        XCTAssertEqual(SigningIdentities.parse(sample), [
            "Developer ID Application: Cubbieblue16 (4NQ2UVJ4EZ)",
            "Apple Development: 152761714+cubbieblue16.noreply.github.com (GZHS2TWCRJ)",
        ])
    }

    func testParseEmptyOutput() {
        XCTAssertEqual(SigningIdentities.parse("     0 valid identities found\n"), [])
    }

    func testDefaultIdentityPrefersDeveloperIDElseAdHoc() {
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: ["Apple Development: x (T)", "Developer ID Application: Y (T2)"]), "Developer ID Application: Y (T2)")
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: ["Apple Development: x (T)"]), AppSettings.adHocIdentityName)
        XCTAssertEqual(SigningIdentities.defaultIdentity(from: []), "Ad-hoc")
    }
}
