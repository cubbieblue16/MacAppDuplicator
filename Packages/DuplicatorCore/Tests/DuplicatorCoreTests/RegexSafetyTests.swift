import XCTest
@testable import DuplicatorCore

final class RegexSafetyTests: XCTestCase {
    func testRejectsNestedUnboundedRepetition() {
        for pattern in ["^(.+)+X$", "(a*)*", "(a+)*", "(a+)+", "(a+)?", "(a+){2,5}", "(a{2,})+", "((a+)b)*", "(?:a+)*",
                        "(?<n>a*)+", "(\\d+)+", "(a+)*?", "(a+)++", "([a-z]+\\s?)*"] {
            XCTAssertNotNil(RegexSafety.unsafeReason(pattern: pattern), pattern)
        }
    }

    func testRejectsBackreferencesLookbehindAndHidingConstructs() {
        for pattern in ["(a)\\1", "(a)(b)\\2", "(?<n>a)\\k<n>", "(?<=a)b", "(?<!a)b", "\\Q(\\E", "(a+\\Q)\\E)*", "(?#c)(a+)*",
                        "(?x)(a+) *", "(?ix:(a+) *)"] {
            XCTAssertNotNil(RegexSafety.unsafeReason(pattern: pattern), pattern)
        }
    }

    func testRejectsOverlongPatterns() {
        XCTAssertNil(RegexSafety.unsafeReason(pattern: String(repeating: "a", count: RegexSafety.maxLength)))
        XCTAssertNotNil(RegexSafety.unsafeReason(pattern: String(repeating: "a", count: RegexSafety.maxLength + 1)))
    }

    func testAcceptsOrdinaryBadgePatterns() {
        for pattern in [#"\((\d+)\)"#, #"^\[(\d+) unread\]"#, "(\\d+)", "^(\\d+) new", "Inbox - (\\d{1,3})", "(a+)b+",
                        "(?:Chat|Mail) \\((\\d+)\\)", "[(+*]+(\\d+)", "x{2}(\\d+)", "a{,3}(\\d+)", "(?i)unread: (\\d+)", "(a)(b)?",
                        "(\\d+)\\)+"] {
            XCTAssertNil(RegexSafety.unsafeReason(pattern: pattern), pattern)
        }
    }

    func testBadgeParserFallsBackFromUnsafePatterns() {
        let parser = BadgeTitleParser(pattern: "^(.+)+X$")
        XCTAssertTrue(parser.usedFallbackPattern)
        XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern)
        // A catastrophic title returns at once instead of backtracking.
        XCTAssertNil(parser.count(in: String(repeating: "a", count: 200)))
        XCTAssertEqual(BadgeTitleParser(pattern: "(\\d+)").count(in: "Inbox 12"), 12)
    }
}
