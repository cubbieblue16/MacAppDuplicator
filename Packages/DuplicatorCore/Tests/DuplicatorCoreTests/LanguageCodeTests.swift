import XCTest
@testable import DuplicatorCore

final class LanguageCodeTests: XCTestCase {
    func testAcceptsLanguageScriptAndRegionCodes() {
        for code in ["en", "fr", "deu", "pt-BR", "zh-Hant", "zh-Hant-TW", "es-419", "EN-us"] {
            XCTAssertTrue(LanguageCode.isValid(code), code)
            XCTAssertNil(LanguageCode.validationMessage(for: code), code)
        }
        XCTAssertNil(LanguageCode.validationMessage(for: nil))
        XCTAssertNil(LanguageCode.validationMessage(for: "   "))
        XCTAssertNil(LanguageCode.validationMessage(for: " fr "))
    }

    func testRefusesMalformedCodes() {
        let malformed = ["", "e", "english", "en_US", "en-", "-en", "en--US", "en-U", "en-abcdefghi", "en US", "en\n", "fr)", "1en", "en;rm"]
        for code in malformed {
            XCTAssertFalse(LanguageCode.isValid(code), code.debugDescription)
        }
        XCTAssertEqual(LanguageCode.validationMessage(for: "en_US"), "Use a language code like en, fr or pt-BR.")
        XCTAssertEqual(LanguageCode.validationMessage(for: "english"), LanguageCode.invalidMessage)
    }
}
