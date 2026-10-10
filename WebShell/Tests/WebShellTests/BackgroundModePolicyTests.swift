@testable import WebShell
import XCTest

final class BackgroundModePolicyTests: XCTestCase {
    func testBackgroundModeNeedsTheMenuBarIcon() {
        let both = BackgroundModePolicy(backgroundMode: true, menuBarIcon: true)
        XCTAssertTrue(both.showsStatusItem)
        XCTAssertTrue(both.keepsRunningWhenWindowCloses)
        XCTAssertFalse(both.terminatesAfterLastWindowClosed)

        let backgroundOnly = BackgroundModePolicy(backgroundMode: true, menuBarIcon: false)
        XCTAssertFalse(backgroundOnly.showsStatusItem)
        XCTAssertFalse(backgroundOnly.keepsRunningWhenWindowCloses)
        XCTAssertTrue(backgroundOnly.terminatesAfterLastWindowClosed)
    }

    func testMenuBarIconAloneShowsTheItemButStillQuitsOnClose() {
        let iconOnly = BackgroundModePolicy(backgroundMode: false, menuBarIcon: true)
        XCTAssertTrue(iconOnly.showsStatusItem)
        XCTAssertFalse(iconOnly.keepsRunningWhenWindowCloses)
        XCTAssertTrue(iconOnly.terminatesAfterLastWindowClosed)

        let neither = BackgroundModePolicy(backgroundMode: false, menuBarIcon: false)
        XCTAssertEqual(neither, BackgroundModePolicy(backgroundMode: true, menuBarIcon: false))
        XCTAssertTrue(neither.terminatesAfterLastWindowClosed)
    }
}
