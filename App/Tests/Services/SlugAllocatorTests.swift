import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class SlugAllocatorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeAppTemporaryDirectory() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    func testFreeSlugIsReturnedUnchanged() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: []), "claude-work")
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-home"]), "claude-work")
    }

    func testTakenSlugGetsTheSuffixTwo() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work"]), "claude-work-2")
    }

    func testSkipsToThreeWhenTwoIsTaken() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work", "claude-work-2"]), "claude-work-3")
    }

    func testTheFirstFreeSuffixWins() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["claude-work", "claude-work-3"]), "claude-work-2")
    }

    /// Launch Services compares bundle ids case-insensitively and the default data folder sits on a case-insensitive
    /// volume, so a hand-edited `Claude-Work` already occupies `claude-work`.
    func testMatchingIgnoresCase() {
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: ["Claude-Work"]), "claude-work-2")
    }

    func testTakenSlugsExcludesTheRecordBeingEdited() throws {
        var work = makeConfig(name: "Claude Work")
        work.slug = "claude-work"
        var home = makeConfig(name: "Claude Home")
        home.slug = "claude-home"
        let workURL = try writeShortcutBundle(named: "Claude Work", in: dir, config: work)
        let homeURL = try writeShortcutBundle(named: "Claude Home", in: dir, config: home)
        let records = [try LibraryScanner.record(forBundleAt: workURL), try LibraryScanner.record(forBundleAt: homeURL)]

        XCTAssertEqual(SlugAllocator.takenSlugs(in: records), ["claude-work", "claude-home"])
        let taken = SlugAllocator.takenSlugs(in: records, excluding: workURL)
        XCTAssertEqual(taken, ["claude-home"])
        // Renaming "Claude Work" to "Claude-Work" folds back to its own slug: it must not collide with itself.
        XCTAssertEqual(SlugAllocator.uniqueSlug(proposed: "claude-work", taken: taken), "claude-work")
    }
}
