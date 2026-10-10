import DuplicatorCore
@testable import WebShell
import XCTest

final class BadgeStateTests: XCTestCase {
    func testWriteReportsChangesAndClampsNegatives() {
        var state = BadgeState()
        XCTAssertNil(state.badgeLabel)
        XCTAssertTrue(state.write(3))
        XCTAssertEqual(state.badgeLabel, "3")
        XCTAssertFalse(state.write(3))
        XCTAssertTrue(state.write(-5))
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.badgeLabel)
        XCTAssertFalse(state.write(0))
    }

    func testTitleWithoutMatchClears() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(BadgeState.count(fromTitle: "Inbox (4) - Mail", parser: parser), 4)
        XCTAssertEqual(BadgeState.count(fromTitle: "Inbox - Mail", parser: parser), 0)
    }
}

@MainActor
final class BadgeControllerTests: XCTestCase {
    private var labels: [String?] = []
    private var published: [Int] = []

    private func makeController(pattern: String? = nil, logger: LaunchLogger) -> BadgeController {
        let controller = BadgeController(parser: BadgeTitleParser(pattern: pattern), logger: logger) { [weak self] label in
            self?.labels.append(label)
        }
        controller.countDidChange = { [weak self] count in
            self?.published.append(count)
        }
        return controller
    }

    func testLastWriterWinsAcrossTitleAndPage() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(logger: logger)
        controller.titleDidChange("Inbox (2)")
        controller.handleMessageBody(["count": 5])
        controller.titleDidChange("Inbox")
        controller.handleMessageBody([String: Any]())
        XCTAssertEqual(labels, ["2", "5", nil])
        XCTAssertEqual(published, [2, 5, 0])
        XCTAssertEqual(controller.count, 0)
        XCTAssertEqual(try loggedMessages(logger), ["badge 2 from title", "badge 5 from page", "badge 0 from title"])
    }

    func testInvalidPatternIsLoggedOnceAtStartup() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(pattern: "(", logger: logger)
        controller.titleDidChange("Inbox (6)")
        XCTAssertEqual(labels, ["6"])
        XCTAssertEqual(try loggedMessages(logger), [
            "badge pattern invalid; using default \(BadgeTitleParser.defaultPattern)",
            "badge 6 from title",
        ])
    }

    func testInvalidMessagesAreDroppedAndLoggedOnce() throws {
        let logger = try makeTemporaryLogger()
        let controller = makeController(logger: logger)
        controller.handleMessageBody("garbage")
        controller.handleMessageBody(["count": -3])
        XCTAssertEqual(labels, [])
        XCTAssertEqual(try loggedMessages(logger), ["badge message dropped (invalid payload)"])
    }
}
