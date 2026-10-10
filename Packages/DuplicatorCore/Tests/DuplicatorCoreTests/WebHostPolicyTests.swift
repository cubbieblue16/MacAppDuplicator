import XCTest
@testable import DuplicatorCore

final class WebHostPolicyTests: XCTestCase {
    private func policy(base: String = "https://web.whatsapp.com", extra: [String] = ["whatsapp.net", "Example.ORG"]) throws -> WebHostPolicy {
        WebHostPolicy(baseURL: try XCTUnwrap(URL(string: base)), extraHosts: extra)
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), string)
    }

    func testMatrix() throws {
        let policy = try policy()
        let cases: [(String, Bool)] = [
            ("https://web.whatsapp.com/", true),            // base host
            ("https://web.whatsapp.com/chat?x=1#frag", true),
            ("HTTPS://WEB.WhatsApp.COM/", true),            // case-insensitive
            ("http://web.whatsapp.com/", true),             // http on an allowed host stays in place
            ("https://static.web.whatsapp.com/", true),     // subdomain of base
            ("https://a.b.web.whatsapp.com/", true),        // nested subdomain
            ("https://whatsapp.net/", true),                // extra host
            ("https://media.whatsapp.net/v/t1", true),      // subdomain of an extra host
            ("https://login.example.org/", true),           // extra host stored in mixed case
            ("https://web.whatsapp.com./", true),           // trailing-dot FQDN
            ("https://whatsapp.com/", false),               // parent of the base host is not allowed
            ("https://evilweb.whatsapp.com.attacker.example/", false),
            ("https://notweb.whatsapp.com/", false),        // suffix without the dot boundary
            ("https://attackerwhatsapp.net/", false),
            ("https://google.com/", false),                 // unrelated host
            ("https://example.com/", false),
            ("mailto:me@web.whatsapp.com", false),
            ("tel:+15555550100", false),
            ("about:blank", false),
            ("data:text/html,hi", false),
            ("blob:https://web.whatsapp.com/1234", false),
            ("javascript:void(0)", false),
            ("ftp://web.whatsapp.com/", false),
            ("file:///etc/hosts", false),
            ("whatsapp://send?phone=1", false),
        ]
        for (string, expected) in cases {
            XCTAssertEqual(policy.allowsInPlace(try url(string)), expected, string)
        }
    }

    func testBaseHostWithWWWDoesNotAllowTheBareDomain() throws {
        let policy = try policy(base: "https://www.example.com", extra: [])
        XCTAssertTrue(policy.allowsInPlace(try url("https://www.example.com/")))
        XCTAssertTrue(policy.allowsInPlace(try url("https://m.www.example.com/")))
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.com/")))
    }

    func testAllowedHostsAreNormalizedBaseFirst() throws {
        let policy = try policy(base: "https://Web.WhatsApp.com", extra: [" WhatsApp.NET ", ".example.org", "", "web.whatsapp.com", "whatsapp.net."])
        XCTAssertEqual(policy.allowedHosts, ["web.whatsapp.com", "whatsapp.net", "example.org"])
    }

    func testNoExtraHostsMeansBaseHostOnly() throws {
        let policy = try policy(base: "https://example.com", extra: [])
        XCTAssertTrue(policy.allowsInPlace(try url("https://sub.example.com/")))
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.net/")))
    }

    func testBaseURLWithoutHostAllowsNothingExceptExtraHosts() throws {
        let policy = try policy(base: "about:blank", extra: ["example.org"])
        XCTAssertEqual(policy.allowedHosts, ["example.org"])
        XCTAssertFalse(policy.allowsInPlace(try url("https://example.com/")))
        XCTAssertTrue(policy.allowsInPlace(try url("https://example.org/")))
    }

    func testInternalSchemes() throws {
        XCTAssertEqual(WebHostPolicy.internalSchemes, ["about", "data", "blob", "javascript"])
        for string in ["about:blank", "data:text/html,hi", "blob:https://web.whatsapp.com/1", "javascript:void(0)", "ABOUT:blank"] {
            XCTAssertTrue(WebHostPolicy.isInternalScheme(try url(string)), string)
        }
        for string in ["https://web.whatsapp.com/", "http://example.com/", "mailto:me@example.com", "tel:+15555550100"] {
            XCTAssertFalse(WebHostPolicy.isInternalScheme(try url(string)), string)
        }
    }
}
