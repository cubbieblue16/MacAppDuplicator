@testable import WebShell
import XCTest

final class WindowSubtitleTests: XCTestCase {
    private func text(_ address: String?) -> String {
        WindowSubtitle.text(for: address.flatMap { URL(string: $0) })
    }

    func testShowsLowercasedHost() {
        XCTAssertEqual(text("https://Mail.Example.COM/inbox?x=1#f"), "mail.example.com")
        XCTAssertEqual(text("https://mail.example.com:8443/"), "mail.example.com")
    }

    func testDropsUserinfoSoItCannotImpersonateTheHost() {
        XCTAssertEqual(text("https://mail.example.com@evil.example/"), "evil.example")
    }

    func testInternationalizedHostStaysPunycode() {
        XCTAssertEqual(text("https://xn--pple-43d.com/"), "xn--pple-43d.com")
    }

    func testNoHostGivesEmptyText() {
        XCTAssertEqual(text(nil), "")
        XCTAssertEqual(text("about:blank"), "")
        XCTAssertEqual(text("blob:null/1234"), "")
    }
}
