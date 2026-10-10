import AppKit
import WebKit
@testable import WebShell
import XCTest

final class DialogPresentationTests: XCTestCase {
    func testAlertTextUsesHostAsTitleAndMessageAsInformativeText() {
        XCTAssertEqual(
            DialogPresentation.alertText(message: "Leave this page?", host: "mail.example.com"),
            .init(title: "mail.example.com", informativeText: "Leave this page?")
        )
    }

    func testAlertTextFallsBackWhenHostIsEmpty() {
        XCTAssertEqual(DialogPresentation.alertText(message: "Hi", host: "").title, DialogPresentation.fallbackTitle)
    }

    func testOnlyTheFirstButtonConfirms() {
        XCTAssertTrue(DialogPresentation.confirmed(.alertFirstButtonReturn))
        XCTAssertFalse(DialogPresentation.confirmed(.alertSecondButtonReturn))
        XCTAssertFalse(DialogPresentation.confirmed(.cancel))
        XCTAssertFalse(DialogPresentation.confirmed(.abort))
    }

    func testTextInputReturnsTextOnlyForOK() {
        XCTAssertEqual(DialogPresentation.textInputResult(.alertFirstButtonReturn, text: "Mike"), "Mike")
        XCTAssertNil(DialogPresentation.textInputResult(.alertSecondButtonReturn, text: "Mike"))
    }

    func testOpenPanelReturnsURLsOnlyForOK() {
        let urls = [URL(filePath: "/tmp/upload.txt")]
        XCTAssertEqual(DialogPresentation.openPanelResult(.OK, urls: urls), urls)
        XCTAssertNil(DialogPresentation.openPanelResult(.cancel, urls: urls))
        XCTAssertNil(DialogPresentation.openPanelResult(.abort, urls: urls))
    }

    func testCoordinatorAnswersTheFourDialogSelectors() {
        XCTAssertTrue(WebViewCoordinator.conforms(to: WKUIDelegate.self))
        let selectors = [
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        ]
        for selector in selectors {
            XCTAssertTrue(WebViewCoordinator.instancesRespond(to: NSSelectorFromString(selector)), selector)
        }
    }
}
