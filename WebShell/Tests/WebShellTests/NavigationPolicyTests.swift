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
        navigationType: WKNavigationType = .linkActivated
    ) throws -> NavigationDecision {
        let url = try XCTUnwrap(URL(string: address))
        let policy = WebHostPolicy(baseURL: try XCTUnwrap(URL(string: "https://mail.example.com/")), extraHosts: ["login.example.net"])
        return NavigationPolicy.decide(
            url: url,
            scheme: url.scheme,
            targetFrameIsMain: targetFrameIsMain,
            navigationType: navigationType,
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
        XCTAssertEqual(try decide("https://LOGIN.example.net/sso", targetFrameIsMain: true), .allow)
        XCTAssertEqual(try decide("http://LOGIN.example.net/sso", targetFrameIsMain: true), .openExternally)
    }

    func testMainFrameHTTPOffPolicyOpensExternally() throws {
        XCTAssertEqual(try decide("https://news.example.org/story", targetFrameIsMain: true), .openExternally)
        XCTAssertEqual(try decide("https://example.com/", targetFrameIsMain: true, navigationType: .other), .openExternally)
    }

    func testNewWindowHTTPIsAllowed() throws {
        XCTAssertEqual(try decide("https://accounts.example.org/oauth", targetFrameIsMain: nil), .allow)
        XCTAssertEqual(try decide("https://mail.example.com/compose", targetFrameIsMain: nil, navigationType: .other), .allow)
    }

    func testPopupWindowsAreNotExemptFromHostPolicy() throws {
        // A popup's own navigations take the same path as the primary view (R2).
        XCTAssertEqual(try decide("https://accounts.example.org/oauth", targetFrameIsMain: true, navigationType: .other), .openExternally)
        XCTAssertEqual(try decide("https://login.example.net/sso", targetFrameIsMain: true, navigationType: .other), .allow)
    }

    func testPopupMailtoLinkClickOpensExternally() throws {
        XCTAssertEqual(
            try decide("mailto:someone@example.com", targetFrameIsMain: true, navigationType: .linkActivated),
            .openExternally
        )
    }

    // MARK: - popupDecision

    private let trustedSource = "https://app.example/inbox"

    private func popup(
        _ address: String?,
        _ type: WKNavigationType,
        sourceIsMainFrame: Bool = true,
        source: String? = "https://app.example/inbox",
        userInitiated: Bool = true
    ) throws -> PopupDecision {
        let policy = WebHostPolicy(baseURL: try XCTUnwrap(URL(string: "https://app.example/")), extraHosts: ["cdn.example"])
        return NavigationPolicy.popupDecision(
            url: address.flatMap { URL(string: $0) },
            navigationType: type,
            sourceIsMainFrame: sourceIsMainFrame,
            sourceURL: source.flatMap { URL(string: $0) },
            userInitiated: userInitiated,
            policy: policy
        )
    }

    func testPopupLinkClickOffPolicyOpensExternally() throws {
        XCTAssertEqual(try popup("https://news.example.org/story", .linkActivated), .openExternally)
        XCTAssertEqual(try popup("http://other.example/", .linkActivated), .openExternally)
        XCTAssertEqual(try popup("https://news.example.org/story", .linkActivated, sourceIsMainFrame: false), .openExternally)
    }

    func testPopupLinkClickOffPolicyWithoutGestureIsIgnored() throws {
        XCTAssertEqual(try popup("https://news.example.org/story", .linkActivated, userInitiated: false), .ignore)
    }

    func testPopupLinkClickInPolicyOpensInApp() throws {
        XCTAssertEqual(try popup("https://app.example/compose", .linkActivated), .openInApp)
        XCTAssertEqual(try popup("https://cdn.example/doc", .linkActivated), .openInApp)
    }

    func testPopupScriptInitiatedFromTrustedMainFrameStaysInApp() throws {
        XCTAssertEqual(try popup("https://accounts.google.example/oauth", .other), .openInApp)
    }

    func testPopupFromSubframeIsNeverInApp() throws {
        XCTAssertEqual(try popup("https://accounts.google.example/oauth", .other, sourceIsMainFrame: false), .openExternally)
        XCTAssertEqual(try popup("https://accounts.google.example/oauth", .other, sourceIsMainFrame: false, userInitiated: false), .ignore)
        XCTAssertEqual(try popup("https://app.example/compose", .linkActivated, sourceIsMainFrame: false), .openExternally)
    }

    func testPopupFromOffPolicySourceHostIsNeverInApp() throws {
        XCTAssertEqual(try popup("https://app.example/x", .other, source: "https://ads.example.org/frame"), .openExternally)
        XCTAssertEqual(try popup("https://app.example/x", .other, source: "https://ads.example.org/frame", userInitiated: false), .ignore)
        XCTAssertEqual(try popup("https://app.example/x", .other, source: nil), .openExternally)
        // http source is not an in-place host under R3.
        XCTAssertEqual(try popup("https://app.example/x", .other, source: "http://app.example/"), .openExternally)
    }

    func testPopupOtherTypesWithoutGestureAreIgnored() throws {
        XCTAssertEqual(try popup("https://x.example.org/", .formSubmitted, sourceIsMainFrame: false), .ignore)
        XCTAssertEqual(try popup("https://x.example.org/", .other, sourceIsMainFrame: false, userInitiated: false), .ignore)
    }

    func testPopupNonWebSchemeIsIgnored() throws {
        XCTAssertEqual(try popup("mailto:a@example.com", .linkActivated), .ignore)
        XCTAssertEqual(try popup("file:///etc/hosts", .other), .ignore)
        XCTAssertEqual(try popup("myapp://callback", .other), .ignore)
    }

    func testPopupBlankFirstFromTrustedScriptOpensInApp() throws {
        // MSAL.js loginPopup opens about:blank first; auth0-spa-js opens '' first; previews open blob: URLs.
        XCTAssertEqual(try popup(nil, .other), .openInApp)
        XCTAssertEqual(try popup("about:blank", .other), .openInApp)
        XCTAssertEqual(try popup("blob:https://app.example/0b7c", .other), .openInApp)
    }

    func testPopupBlankFirstFromUntrustedSourceIsIgnored() throws {
        XCTAssertEqual(try popup(nil, .other, sourceIsMainFrame: false), .ignore)
        XCTAssertEqual(try popup("about:blank", .other, source: "https://ads.example.org/"), .ignore)
    }

    func testPopupBlankFromLinkClickIsIgnored() throws {
        XCTAssertEqual(try popup(nil, .linkActivated), .ignore)
        XCTAssertEqual(try popup("about:blank", .linkActivated), .ignore)
    }
}
