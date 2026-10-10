import XCTest
@testable import MacAppDuplicator

final class RebuildSummaryTests: XCTestCase {
    private func result(_ name: String, _ outcome: RebuildResult.Outcome) -> RebuildResult {
        RebuildResult(id: URL(fileURLWithPath: "/Shortcuts/\(name).app"), name: name, outcome: outcome)
    }

    func testCountsRebuiltShortcutsWithTheRightNoun() {
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .rebuilt)]), "Rebuilt 1 of 1 shortcut.")
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .rebuilt), result("Two", .rebuilt)]), "Rebuilt 2 of 2 shortcuts.")
        XCTAssertEqual(RebuildSummary.text(for: []), "No shortcuts needed a rebuild.")
    }

    func testReportsFailuresNextToTheRebuiltCount() {
        let results = [
            result("One", .rebuilt),
            result("Two", .failed("The target app was not found at /Applications/Two.app.")),
            result("Three", .failed("codesign failed")),
        ]
        XCTAssertEqual(RebuildSummary.text(for: results), "Rebuilt 1 of 3 shortcuts; 2 failed.")
        XCTAssertEqual(RebuildSummary.text(for: [result("One", .failed("codesign failed"))]), "Rebuilt 0 of 1 shortcut; 1 failed.")
    }
}
