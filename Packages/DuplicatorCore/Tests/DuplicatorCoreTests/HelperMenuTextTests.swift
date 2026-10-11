import XCTest
@testable import DuplicatorCore

final class HelperMenuTextTests: XCTestCase {
    func testMenuTitlesNameTheShortcut() {
        XCTAssertEqual(HelperMenuText.show(name: "Claude Work"), "Show Claude Work")
        XCTAssertEqual(HelperMenuText.newWindow, "New Window")
        XCTAssertEqual(HelperMenuText.quit(name: "Claude Work"), "Quit Claude Work")
    }
}
