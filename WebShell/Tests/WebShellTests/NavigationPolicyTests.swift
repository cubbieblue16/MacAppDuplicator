import DuplicatorCore
import WebKit
@testable import WebShell
import XCTest

/// `NavigationPolicy.decide` (skeleton decision 6), as left by Task 2's fix waves.
final class NavigationPolicyTests: XCTestCase {
    /// Base host `mail.example.com`; `login.example.net` is an extra in-place host.
    private func decide(
        _ address: String,
        targetFrameIsMain: Bool?,
        navigationType: WKNavigationType = .linkActivated,
        isPrimaryWebView: Bool = true
    ) throws -> NavigationDecision {
        let url = try XCTUnwrap(URL(string: address))
        let policy = WebHostPolicy(baseURL: try XCTUnwrap(URL(string: "https://mail.example.com/")), extraHosts: ["login.example.net"])
        return NavigationPolicy.decide(
            url: url,
            scheme: url.scheme,
            targetFrameIsMain: targetFrameIsMain,
            navigationType: navigationType,
            isPrimaryWebView: isPrimaryWebView,
            policy: policy
        )
    }

    func testSubframeNonHTTPIsAllowed() throws {
        XCTAssertEqual(try decide("mailto:someone@example.com", targetFrameIsMain: false), .allow)
        XCTAssertEqual(try decide("file:///etc/hosts", targetFrameIsMain: false, navigationType: .other), .allow)
        XCTAssertEqual(try decide("zoommtg://zoom.us/join", targetFrameIsMain: false), .allow)
    }

    func testNewWindowMailtoLinkClickOpensExternally() throws {
        XCTAssertEqual(try decide("mailto:someone@example.com", targetFrameIsMain: nil, navigationType: .linkActivated), .openExternally)
    }

    func testNewWindowMailtoWithoutLinkClickIsBlocked() throws {
        XCTAssertEqual(
            try decide("mailto:someone@example.com", targetFrameIsMain: nil, navigationType: .other),
            .blocked(reason: "blocked scheme=mailto")
        )
    }

    func testMainFrameFileIsBlockedAndNeverOpenedExternally() throws {
        XCTAssertEqual(try decide("file:///etc/hosts", targetFrameIsMain: true, navigationType: .linkActivated), .blocked(reason: "blocked scheme=file"))
        XCTAssertEqual(try decide("file:///etc/hosts", targetFrameIsMain: true, navigationType: .other), .blocked(reason: "blocked scheme=file"))
    }

    func testAboutSrcdocAndBlankAreAllowed() throws {
        XCTAssertEqual(try decide("about:srcdoc", targetFrameIsMain: true), .allow)
        XCTAssertEqual(try decide("about:blank", targetFrameIsMain: true, navigationType: .other), .allow)
        XCTAssertEqual(try decide("about:blank", targetFrameIsMain: nil, navigationType: .other), .allow)
    }

    func testMainFrameHTTPInPolicyIsAllowed() throws {
        XCTAssertEqual(try decide("https://mail.example.com/inbox?folder=1", targetFrameIsMain: true), .allow)
        XCTAssertEqual(try decide("https://eu.mail.example.com/", targetFrameIsMain: true, navigationType: .other), .allow)
        XCTAssertEqual(try decide("http://LOGIN.example.net/sso", targetFrameIsMain: true), .allow)
    }

    func testMainFrameHTTPOffPolicyOpensExternally() throws {
        XCTAssertEqual(try decide("https://news.example.org/story", targetFrameIsMain: true), .openExternally)
        XCTAssertEqual(try decide("https://example.com/", targetFrameIsMain: true, navigationType: .other), .openExternally)
    }

    func testNewWindowHTTPIsAllowed() throws {
        XCTAssertEqual(try decide("https://accounts.example.org/oauth", targetFrameIsMain: nil), .allow)
        XCTAssertEqual(try decide("https://mail.example.com/compose", targetFrameIsMain: nil, navigationType: .other), .allow)
    }

    func testPopupMainFrameHTTPOffPolicyIsAllowed() throws {
        XCTAssertEqual(try decide("https://accounts.example.org/oauth", targetFrameIsMain: true, isPrimaryWebView: false), .allow)
    }

    func testPopupMailtoLinkClickOpensExternally() throws {
        XCTAssertEqual(
            try decide("mailto:someone@example.com", targetFrameIsMain: true, navigationType: .linkActivated, isPrimaryWebView: false),
            .openExternally
        )
    }

    // MARK: - popupDecision

    private func popup(_ address: String?, _ type: WKNavigationType) throws -> PopupDecision {
        let policy = WebHostPolicy(baseURL: try XCTUnwrap(URL(string: "https://app.example/")), extraHosts: ["cdn.example"])
        return NavigationPolicy.popupDecision(url: address.flatMap { URL(string: $0) }, navigationType: type, policy: policy)
    }

    func testPopupLinkClickOffPolicyOpensExternally() throws {
        XCTAssertEqual(try popup("https://news.example.org/story", .linkActivated), .openExternally)
        XCTAssertEqual(try popup("http://other.example/", .linkActivated), .openExternally)
    }

    func testPopupLinkClickInPolicyOpensInApp() throws {
        XCTAssertEqual(try popup("https://app.example/compose", .linkActivated), .openInApp)
        XCTAssertEqual(try popup("https://cdn.example/doc", .linkActivated), .openInApp)
    }

    func testPopupScriptInitiatedStaysInApp() throws {
        XCTAssertEqual(try popup("https://accounts.google.example/oauth", .other), .openInApp)
    }

    func testPopupNonWebSchemeIsIgnored() throws {
        XCTAssertEqual(try popup("mailto:a@example.com", .linkActivated), .ignore)
        XCTAssertEqual(try popup("file:///etc/hosts", .other), .ignore)
        XCTAssertEqual(try popup("myapp://callback", .other), .ignore)
    }

    func testPopupBlankFirstFromScriptOpensInApp() throws {
        // MSAL.js loginPopup opens about:blank first; auth0-spa-js opens '' first; previews open blob: URLs.
        XCTAssertEqual(try popup(nil, .other), .openInApp)
        XCTAssertEqual(try popup("about:blank", .other), .openInApp)
        XCTAssertEqual(try popup("blob:https://app.example/0b7c", .other), .openInApp)
    }

    func testPopupBlankFromLinkClickIsIgnored() throws {
        XCTAssertEqual(try popup(nil, .linkActivated), .ignore)
        XCTAssertEqual(try popup("about:blank", .linkActivated), .ignore)
    }
}
