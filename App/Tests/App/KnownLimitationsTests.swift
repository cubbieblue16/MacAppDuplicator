import XCTest
@testable import MacAppDuplicator

final class KnownLimitationsTests: XCTestCase {
    func testEntriesAreUniqueAndNonEmpty() {
        let ids = KnownLimitations.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThanOrEqual(KnownLimitations.all.count, 6)
        for item in KnownLimitations.all {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.detail.isEmpty)
        }
    }

    func testCoversSpecSection11Topics() {
        let ids = Set(KnownLimitations.all.map(\.id))
        for required in ["launch-constraints", "sandboxed-apps", "single-instance", "dock-redraw", "login-items", "updates", "notifications", "file-associations"] {
            XCTAssertTrue(ids.contains(required), "missing \(required)")
        }
    }
}
