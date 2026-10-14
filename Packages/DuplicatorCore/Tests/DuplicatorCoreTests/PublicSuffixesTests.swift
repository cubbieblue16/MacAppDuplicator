import XCTest
@testable import DuplicatorCore

final class PublicSuffixesTests: XCTestCase {
    func testRejectsSingleLabelsAndListedSuffixes() {
        for host in ["com", "uk", "localhost", "co.uk", "ORG.UK", "github.io", "herokuapp.com", "amazonaws.com", "pages.dev",
                     "workers.dev", "web.app", " co.jp ", "co.uk.", ".com", "", "a..com"] {
            XCTAssertFalse(PublicSuffixes.isAcceptableExtraHost(host), host)
        }
    }

    func testAcceptsRegistrableDomainsAndSubdomainsOfSharedSuffixes() {
        for host in ["whatsapp.com", "Office.COM", "foo.github.io", "example.co.uk", "cdn.example.com", "10.0.0.1"] {
            XCTAssertTrue(PublicSuffixes.isAcceptableExtraHost(host), host)
        }
    }

    func testWebAppConfigDropsTrustedRegistries() {
        let config = WebAppConfig(url: "https://mail.example.com", extraHosts: ["com", "co.uk", "example.com", "github.io"])
        XCTAssertEqual(config.extraHosts, ["example.com"])
    }

    func testWebHostPolicyDoesNotTrustARegistryEvenIfHandedOne() throws {
        let policy = WebHostPolicy(baseURL: try XCTUnwrap(URL(string: "https://mail.example.org")), extraHosts: ["com", "co.uk"])
        XCTAssertEqual(policy.allowedHosts, ["mail.example.org"])
        XCTAssertFalse(policy.allowsInPlace(try XCTUnwrap(URL(string: "https://evil.com/"))))
    }
}
