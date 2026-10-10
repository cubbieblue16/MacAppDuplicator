import AppKit
@testable import WebShell
import XCTest

final class StatusItemTextTests: XCTestCase {
    func testTitleShowsCountOnlyAboveZero() {
        XCTAssertEqual(StatusItemText.title(forCount: 0), "")
        XCTAssertEqual(StatusItemText.title(forCount: -1), "")
        XCTAssertEqual(StatusItemText.title(forCount: 3), "3")
    }

    func testMenuItemTitles() {
        XCTAssertEqual(StatusItemText.showItemTitle(appName: "Gmail"), "Show Gmail")
        XCTAssertEqual(StatusItemText.quitItemTitle(appName: "Gmail"), "Quit Gmail")
    }

    func testAppNameComesFromBundleName() {
        XCTAssertEqual(StatusItemText.appName(infoDictionary: ["CFBundleName": "Gmail"], fallback: "Shell"), "Gmail")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: ["CFBundleName": ""], fallback: "Shell"), "Shell")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: [:], fallback: "Shell"), "Shell")
        XCTAssertEqual(StatusItemText.appName(infoDictionary: nil, fallback: "Shell"), "Shell")
    }

    @MainActor
    func testMenuBarImageIsAResized18PointCopy() {
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        let image = StatusItemController.menuBarImage(from: icon)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 512, height: 512))
        XCTAssertFalse(image === icon)
    }
}
