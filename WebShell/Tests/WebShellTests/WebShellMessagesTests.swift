import DuplicatorCore
@testable import WebShell
import XCTest

final class WebShellMessagesTests: XCTestCase {
    private let idText = "6f9619ff-8b86-4011-b42d-00c04fc964ff"

    func testBadgeCountAcceptsWholeNumbers() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 3]), 3)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 3.0]), 3)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": 0]), 0)
    }

    func testBadgeCountParsesNumericStrings() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": "7"]), 7)
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": "seven"]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": "-2"]))
    }

    func testBadgeCountClearsWhenCountIsAbsent() {
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: [String: Any]()), 0)
        XCTAssertEqual(WebShellMessages.badgeCount(fromMessageBody: ["count": NSNull()]), 0)
    }

    func testBadgeCountDropsInvalidBodies() {
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: "3"))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": -1]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": 2.5]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": true]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": 1e300]))
        XCTAssertNil(WebShellMessages.badgeCount(fromMessageBody: ["count": [1]]))
    }

    func testNotificationAcceptsShimPayload() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        let message = WebShellMessages.notification(fromMessageBody: [
            "id": idText, "title": "New mail", "body": "Lunch?", "tag": "inbox",
        ])
        XCTAssertEqual(message, .show(id: id, title: "New mail", body: "Lunch?", tag: "inbox"))
    }

    func testNotificationDefaultsBodyAndDropsEmptyTag() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        let message = WebShellMessages.notification(fromMessageBody: ["id": idText, "title": "Ping", "tag": ""])
        XCTAssertEqual(message, .show(id: id, title: "Ping", body: "", tag: nil))
    }

    func testNotificationClose() throws {
        let id = try XCTUnwrap(UUID(uuidString: idText))
        XCTAssertEqual(WebShellMessages.notification(fromMessageBody: ["id": idText, "close": true]), .close(id: id))
    }

    func testNotificationDropsInvalidIDs() {
        let bodies: [Any] = [
            ["title": "No id"],
            ["id": "not-a-uuid", "title": "Garbage"],
            ["id": "", "title": "Empty"],
            ["id": 42, "title": "Number"],
            ["id": idText + "-junk", "title": "Trailing junk"],
            ["id": idText, "close": "yes", "title": 5],
            "not a dictionary",
        ]
        for body in bodies {
            XCTAssertNil(WebShellMessages.notification(fromMessageBody: body), "\(body)")
        }
    }

    func testNotificationRequiresStringTitle() {
        XCTAssertNil(WebShellMessages.notification(fromMessageBody: ["id": idText]))
        XCTAssertNil(WebShellMessages.notification(fromMessageBody: ["id": idText, "title": 5]))
    }

    func testNotificationTruncatesLongText() throws {
        let long = String(repeating: "x", count: 5_000)
        let message = WebShellMessages.notification(fromMessageBody: ["id": idText, "title": long, "body": long, "tag": long])
        guard case let .show(_, title, body, tag) = try XCTUnwrap(message) else {
            return XCTFail("expected .show, got \(String(describing: message))")
        }
        XCTAssertEqual(title.count, WebShellMessages.maxTextLength)
        XCTAssertEqual(body.count, WebShellMessages.maxTextLength)
        XCTAssertEqual(tag?.count, WebShellMessages.maxTextLength)
    }

    func testLoggableTitleFlattensControlCharactersAndTruncates() {
        XCTAssertEqual(WebShellMessages.loggableTitle("a\nb\tc\u{2028}d"), "a b c d")
        XCTAssertEqual(WebShellMessages.loggableTitle(String(repeating: "y", count: 500)).count, WebShellMessages.maxLoggedTitleLength)
    }

    // MARK: - isTrustedOrigin

    private var originPolicy: WebHostPolicy {
        WebHostPolicy(baseURL: URL(string: "https://app.example/")!, extraHosts: ["cdn.example"])
    }

    func testTrustedOriginAcceptsAppAndExtraHosts() {
        XCTAssertTrue(WebShellMessages.isTrustedOrigin(scheme: "https", host: "app.example", policy: originPolicy))
        XCTAssertTrue(WebShellMessages.isTrustedOrigin(scheme: "https", host: "Mail.APP.example", policy: originPolicy))
        XCTAssertTrue(WebShellMessages.isTrustedOrigin(scheme: "http", host: "cdn.example", policy: originPolicy))
    }

    func testTrustedOriginRejectsForeignHostsAndSchemes() {
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "https", host: "evil.example", policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "https", host: "app.example.evil.example", policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "https", host: nil, policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "https", host: "", policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: nil, host: "app.example", policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "file", host: "app.example", policy: originPolicy))
        XCTAssertFalse(WebShellMessages.isTrustedOrigin(scheme: "about", host: "app.example", policy: originPolicy))
    }
}
