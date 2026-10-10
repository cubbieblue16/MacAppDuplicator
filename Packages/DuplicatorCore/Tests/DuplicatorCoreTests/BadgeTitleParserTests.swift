import XCTest
@testable import DuplicatorCore

final class BadgeTitleParserTests: XCTestCase {
    func testDefaultPatternConstant() {
        XCTAssertEqual(BadgeTitleParser.defaultPattern, #"\((\d+)\)"#)
        XCTAssertEqual(BadgeTitleParser(pattern: nil).pattern, BadgeTitleParser.defaultPattern)
    }

    func testDefaultPatternFindsTheCount() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(parser.count(in: "(3) WhatsApp"), 3)
        XCTAssertEqual(parser.count(in: "Inbox (12) - mail"), 12)
        XCTAssertEqual(parser.count(in: "(7) first (9) second"), 7)
        XCTAssertEqual(parser.count(in: "(0) Teams"), 0)
        XCTAssertEqual(parser.count(in: "(5) Café – naïve ☕"), 5)
        XCTAssertFalse(parser.usedFallbackPattern)
    }

    func testTitlesWithoutAMatchReturnNil() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertNil(parser.count(in: "WhatsApp"))
        XCTAssertNil(parser.count(in: ""))
        XCTAssertNil(parser.count(in: "(three) WhatsApp"))
        XCTAssertNil(parser.count(in: "()"))
        XCTAssertNil(parser.count(in: "(99999999999999999999999) overflow"))
    }

    func testCustomPattern() {
        let parser = BadgeTitleParser(pattern: #"^\[(\d+) unread\]"#)
        XCTAssertEqual(parser.pattern, #"^\[(\d+) unread\]"#)
        XCTAssertFalse(parser.usedFallbackPattern)
        XCTAssertEqual(parser.count(in: "[4 unread] Mail"), 4)
        XCTAssertNil(parser.count(in: "(4) Mail"), "the default pattern no longer applies")
        XCTAssertNil(parser.count(in: "Mail [4 unread]"), "the custom pattern is anchored")
    }

    func testBlankPatternSelectsTheDefaultWithoutCountingAsInvalid() {
        for blank in ["", "   ", "\n"] {
            let parser = BadgeTitleParser(pattern: blank)
            XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern)
            XCTAssertFalse(parser.usedFallbackPattern)
        }
    }

    func testInvalidPatternFallsBackToTheDefault() {
        for invalid in ["(", "[a-", #"(\d+"#, "*abc", #"\"#] {
            let parser = BadgeTitleParser(pattern: invalid)
            XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern, invalid)
            XCTAssertTrue(parser.usedFallbackPattern, invalid)
            XCTAssertEqual(parser.count(in: "(8) Chat"), 8, invalid)
        }
    }

    func testPatternWithoutACaptureGroupFallsBackToTheDefault() {
        let parser = BadgeTitleParser(pattern: #"\d+"#)
        XCTAssertTrue(parser.usedFallbackPattern)
        XCTAssertEqual(parser.pattern, BadgeTitleParser.defaultPattern)
        XCTAssertEqual(parser.count(in: "(2) Chat"), 2)
    }

    func testOnlyTheFirstCaptureGroupCounts() {
        let parser = BadgeTitleParser(pattern: #"(\w+): (\d+)"#)
        XCTAssertNil(parser.count(in: "Inbox: 5"), "first group is the word, which is not a number")
        let numeric = BadgeTitleParser(pattern: #"(\d+) of (\d+)"#)
        XCTAssertEqual(numeric.count(in: "3 of 10"), 3)
    }

    func testLongTitlesAreCutBeforeMatching() {
        let parser = BadgeTitleParser(pattern: nil)
        XCTAssertEqual(parser.count(in: "(6) " + String(repeating: "x", count: 5_000)), 6)
        XCTAssertNil(parser.count(in: String(repeating: "x", count: BadgeTitleParser.maxTitleLength) + " (6)"))
    }
}
