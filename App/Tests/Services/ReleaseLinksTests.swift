import XCTest
@testable import MacAppDuplicator

final class ReleaseLinksTests: XCTestCase {
    func testRepositoryIsTheGitHubProject() {
        XCTAssertEqual(ReleaseLinks.repository.absoluteString, "https://github.com/cubbieblue16/MacAppDuplicator")
    }

    func testLatestReleaseIsTheGitHubLatestReleasePage() {
        XCTAssertEqual(
            ReleaseLinks.latestRelease.absoluteString,
            "https://github.com/cubbieblue16/MacAppDuplicator/releases/latest"
        )
    }
}
