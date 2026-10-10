import DuplicatorCore
@testable import WebShell
import XCTest

@MainActor
final class FakeNotificationPoster: NotificationPosting {
    struct Posted: Equatable {
        let id: UUID
        let title: String
        let body: String
        let tag: String?
    }

    private(set) var posted: [Posted] = []
    private(set) var removed: [UUID] = []
    private(set) var onClick: (@MainActor (String) -> Void)?

    func start(onClick: @escaping @MainActor (String) -> Void) {
        self.onClick = onClick
    }

    func post(id: UUID, title: String, body: String, tag: String?) {
        posted.append(Posted(id: id, title: title, body: body, tag: tag))
    }

    func removeDelivered(id: UUID) {
        removed.append(id)
    }
}

final class NotificationTargetsTests: XCTestCase {
    func testEvictsOldestBeyondCapacity() {
        let first = UUID(), second = UUID(), third = UUID()
        var targets = NotificationTargets<Int>(capacity: 2)
        targets.insert(1, for: first)
        targets.insert(2, for: second)
        targets.insert(3, for: third)
        XCTAssertEqual(targets.count, 2)
        XCTAssertNil(targets[first])
        XCTAssertEqual(targets[second], 2)
        XCTAssertEqual(targets.remove(third), 3)
        XCTAssertNil(targets.remove(third))
        XCTAssertEqual(targets.count, 1)
    }
}

@MainActor
final class NotificationRouterTests: XCTestCase {
    private var events: [String] = []

    private func makeRouter(poster: FakeNotificationPoster, logger: LaunchLogger) -> NotificationRouter<Int> {
        NotificationRouter<Int>(
            poster: poster,
            logger: logger,
            bringToFront: { [weak self] in self?.events.append("front") },
            dispatch: { [weak self] script, target in self?.events.append("dispatch \(target) \(script)") }
        )
    }

    func testShowPostsAndLogsTitleOnly() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "New mail", "body": "secret body", "tag": "inbox"], from: 1)
        XCTAssertEqual(poster.posted, [.init(id: id, title: "New mail", body: "secret body", tag: "inbox")])
        XCTAssertEqual(router.pendingCount, 1)
        let messages = try loggedMessages(logger)
        XCTAssertEqual(messages, ["notification \"New mail\""])
        XCTAssertFalse(messages.contains { $0.contains("secret body") })
    }

    func testInvalidIDIsDroppedAndLoggedOnce() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        router.receive(["id": "nope", "title": "x"], from: 1)
        router.receive(["title": "y"], from: 1)
        XCTAssertEqual(poster.posted, [])
        XCTAssertEqual(router.pendingCount, 0)
        XCTAssertEqual(try loggedMessages(logger), ["notification message dropped (invalid payload)"])
    }

    func testClickBringsWindowForwardThenDispatchesToOriginTarget() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        router.start()
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "Ping"], from: 7)
        let onClick = try XCTUnwrap(poster.onClick)
        onClick(id.uuidString)
        XCTAssertEqual(events, ["front", "dispatch 7 \(WebShellScripts.notificationClickedScript(id: id))"])
        XCTAssertEqual(router.pendingCount, 0)
    }

    func testCloseRemovesDeliveredAndForgetsTarget() throws {
        let logger = try makeTemporaryLogger()
        let poster = FakeNotificationPoster()
        let router = makeRouter(poster: poster, logger: logger)
        let id = UUID()
        router.receive(["id": id.uuidString.lowercased(), "title": "Ping"], from: 3)
        router.receive(["id": id.uuidString.lowercased(), "close": true], from: 3)
        XCTAssertEqual(poster.removed, [id])
        router.click(identifier: id.uuidString)
        XCTAssertEqual(events, ["front"])
        XCTAssertEqual(try loggedMessages(logger).last, "notification click: page no longer holds it")
    }

    func testClickWithGarbageIdentifierOnlyBringsWindowForward() throws {
        let logger = try makeTemporaryLogger()
        let router = makeRouter(poster: FakeNotificationPoster(), logger: logger)
        router.click(identifier: "garbage")
        XCTAssertEqual(events, ["front"])
    }
}
