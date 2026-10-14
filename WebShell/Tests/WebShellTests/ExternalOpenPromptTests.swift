@testable import WebShell
import XCTest

final class ExternalOpenPromptTests: XCTestCase {
    private func prompt(_ address: String, handler: String? = "Screen Sharing") throws -> ExternalOpenPrompt? {
        ExternalOpenPrompt.make(for: try XCTUnwrap(URL(string: address)), handlerName: handler)
    }

    func testMailtoIsExempt() throws {
        XCTAssertNil(try prompt("mailto:someone@example.com"))
        XCTAssertNil(try prompt("MAILTO:someone@example.com"))
    }

    func testVNCSMBAndSSHPrompt() throws {
        XCTAssertEqual(try prompt("vnc://10.0.0.5")?.messageText, "Open vnc link in Screen Sharing?")
        XCTAssertEqual(try prompt("smb://nas.local/share", handler: "Finder")?.messageText, "Open smb link in Finder?")
        XCTAssertEqual(try prompt("ssh://root@host", handler: "Terminal")?.messageText, "Open ssh link in Terminal?")
        XCTAssertEqual(try prompt("ssh://root@host", handler: "Terminal")?.informativeText, "ssh://root@host")
    }

    func testUnknownHandlerFallsBackToGenericName() throws {
        XCTAssertEqual(try prompt("zoommtg://zoom.us/join", handler: nil)?.messageText, "Open zoommtg link in an external app?")
        XCTAssertEqual(try prompt("zoommtg://zoom.us/join", handler: "")?.messageText, "Open zoommtg link in an external app?")
    }

    func testWebSchemesDoNotPrompt() throws {
        XCTAssertNil(try prompt("https://example.com/"))
        XCTAssertNil(try prompt("http://example.com/"))
    }

    func testLongURLIsTruncatedTo200Characters() throws {
        let long = "vnc://host/" + String(repeating: "a", count: 500)
        let shown = try XCTUnwrap(try prompt(long)).informativeText
        XCTAssertEqual(shown.count, ExternalOpenPrompt.maxDisplayedURLLength + 3)
        XCTAssertTrue(shown.hasPrefix("vnc://host/aaa"))
        XCTAssertTrue(shown.hasSuffix("..."))
    }

    func testButtonTitles() throws {
        let prompt = try XCTUnwrap(try prompt("vnc://host"))
        XCTAssertEqual(prompt.openButtonTitle, "Open")
        XCTAssertEqual(prompt.cancelButtonTitle, "Cancel")
    }
}
