import XCTest
@testable import DuplicatorCore

final class HelperArgumentsTests: XCTestCase {
    private let launcher = "/Users/test/Applications/App Duplicator/Claude Work.app/Contents/MacOS/Claude Work"
    private let bundle = "/Users/test/Applications/App Duplicator/Claude Work.app"
    private let dataPath = "/Users/test/Library/Application Support/App Duplicator/claude-work"

    func testArgumentsRoundTripThroughParse() {
        let withData = HelperArguments(
            parentPID: 4242,
            startTime: ProcessStartTime(seconds: 1_760_000_000, microseconds: 999_999),
            bundlePath: bundle,
            dataPath: dataPath
        )
        XCTAssertEqual(withData.arguments, ["--helper", "4242", "1760000000", "999999", bundle, dataPath])
        XCTAssertEqual(HelperArguments.parse([launcher] + withData.arguments), withData)

        let withoutData = HelperArguments(
            parentPID: 2, startTime: ProcessStartTime(seconds: 0, microseconds: 0), bundlePath: bundle, dataPath: nil
        )
        XCTAssertEqual(withoutData.arguments.last, "-")
        XCTAssertEqual(HelperArguments.parse([launcher] + withoutData.arguments), withoutData)
    }

    func testOnlyTheFlagInSecondPlaceSelectsTheHelperRole() {
        XCTAssertTrue(HelperArguments.isHelperInvocation([launcher, "--helper"]))
        XCTAssertTrue(HelperArguments.isHelperInvocation([launcher, "--helper", "1"]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher, "-psn_0_12345", "--helper"]))
        XCTAssertFalse(HelperArguments.isHelperInvocation([launcher, "--helper=1"]))
    }

    func testParseRefusesWrongCountsAndBadNumbers() {
        let good = ["--helper", "4242", "1760000000", "5", bundle, dataPath]
        XCTAssertNotNil(HelperArguments.parse([launcher] + good))
        XCTAssertNil(HelperArguments.parse([launcher] + good.dropLast()))
        XCTAssertNil(HelperArguments.parse([launcher] + good + ["extra"]))
        XCTAssertNil(HelperArguments.parse(good))
        let badValues: [(index: Int, value: String)] = [
            (1, "1"), (1, "0"), (1, "-7"), (1, "abc"), (1, "99999999999"),
            (2, "-1"), (2, "1.5"), (3, "1000000"), (3, "x"),
        ]
        for bad in badValues {
            var argv = good
            argv[bad.index] = bad.value
            XCTAssertNil(HelperArguments.parse([launcher] + argv), "\(bad.index) \(bad.value)")
        }
    }

    func testParseRefusesARelativeBundleAndAnEmptyDataPath() {
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", "Claude Work.app", dataPath]))
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", "", dataPath]))
        XCTAssertNil(HelperArguments.parse([launcher, "--helper", "4242", "1", "2", bundle, ""]))
        // A relative data path parses; EraseOnQuitPolicy refuses it and the helper logs why.
        XCTAssertEqual(
            HelperArguments.parse([launcher, "--helper", "4242", "1", "2", bundle, "relative/data"])?.dataPath,
            "relative/data"
        )
    }
}
