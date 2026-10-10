import XCTest
@testable import CompatProfiles

final class ProfilesFetchPolicyTests: XCTestCase {
    private func assertThrows(_ expected: ProfilesError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ProfilesError, expected, file: file, line: line)
        }
    }

    func testDefaultURLAndCacheLocation() {
        XCTAssertEqual(ProfilesConstants.defaultURLString,
                       "https://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/Packages/CompatProfiles/Resources/profiles.json")
        XCTAssertEqual(ProfilesConstants.defaultCacheURL(home: URL(filePath: "/Users/test", directoryHint: .isDirectory)).path,
                       "/Users/test/Library/Application Support/App Duplicator/profiles.json")
    }

    func testAllowsOnlyHTTPSToRawGitHubUserContent() throws {
        let allowed = [
            ProfilesConstants.defaultURLString,
            "https://raw.githubusercontent.com:443/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "HTTPS://RAW.GITHUBUSERCONTENT.COM/cubbieblue16/MacAppDuplicator/main/profiles.json",
        ]
        let refused = [
            "http://raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://raw.githubusercontent.com:8443/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://someone:hunter2@raw.githubusercontent.com/cubbieblue16/MacAppDuplicator/main/profiles.json",
            "https://raw.githubusercontent.com.example.com/profiles.json",
            "https://github.com/cubbieblue16/MacAppDuplicator/raw/main/profiles.json",
            "https://example.com/raw.githubusercontent.com/profiles.json",
            "file:///Users/test/profiles.json",
            "ftp://raw.githubusercontent.com/profiles.json",
        ]

        for raw in allowed {
            XCTAssertTrue(ProfilesFetchPolicy.isAllowedSource(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in refused {
            XCTAssertFalse(ProfilesFetchPolicy.isAllowedSource(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testRedirectTargetsFollowTheSameRule() {
        XCTAssertTrue(ProfilesFetchPolicy.allowsRedirect(
            to: URL(string: "https://raw.githubusercontent.com/cubbieblue16/Renamed/main/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: URL(string: "https://objects.githubusercontent.com/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: URL(string: "http://raw.githubusercontent.com/profiles.json")))
        XCTAssertFalse(ProfilesFetchPolicy.allowsRedirect(to: nil))
    }

    func testCheckResponseAcceptsOnlyA200FromTheAllowedHostWithinTheCap() throws {
        let source = try XCTUnwrap(URL(string: ProfilesConstants.defaultURLString))

        XCTAssertNoThrow(try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source, expectedContentLength: -1))
        XCTAssertNoThrow(try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source,
                                                               expectedContentLength: Int64(ProfilesDocument.maxBytes)))
        assertThrows(.httpStatus(404)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 404, finalURL: source, expectedContentLength: 14)
        }
        assertThrows(.httpStatus(302)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 302, finalURL: source, expectedContentLength: 0)
        }
        assertThrows(.insecureURL("https://example.com/profiles.json")) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: URL(string: "https://example.com/profiles.json"),
                                                  expectedContentLength: -1)
        }
        assertThrows(.insecureURL("")) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: nil, expectedContentLength: -1)
        }
        assertThrows(.tooLarge(ProfilesDocument.maxBytes + 1)) {
            try ProfilesFetchPolicy.checkResponse(statusCode: 200, finalURL: source,
                                                  expectedContentLength: Int64(ProfilesDocument.maxBytes + 1))
        }
    }
}
