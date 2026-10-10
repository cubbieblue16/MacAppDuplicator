import Darwin
import Foundation
import XCTest
@testable import MacAppDuplicator

/// Counts debounced change callbacks on the main actor and optionally reports each one.
@MainActor
final class ChangeCounter {
    private(set) var count = 0
    var onRecord: (() -> Void)?

    func record() {
        count += 1
        onRecord?()
    }
}

final class FolderWatcherTests: XCTestCase {
    @MainActor
    func testDeallocatedWatcherWithoutStopClosesItsDescriptorAndNeverCallsBack() async throws {
        let folder = try makeAppTemporaryDirectory()
        let counter = ChangeCounter()
        var watcher: FolderWatcher? = FolderWatcher(folders: [folder], debounce: .milliseconds(50)) { counter.record() }
        watcher?.start()
        XCTAssertEqual(watcher?.watchedSourceCount, 1)
        XCTAssertEqual(Self.openDescriptorCount(for: folder), 1, "start() opens one O_EVTONLY descriptor per folder")

        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        await waitUntil { counter.count == 1 }
        XCTAssertEqual(counter.count, 1, "the watcher must report a change while alive")

        weak let released = watcher
        watcher = nil  // no stop(): deinit alone must clean up (final review M8)
        XCTAssertNil(released, "nothing may retain the watcher, or deinit never runs")

        await waitUntil { Self.openDescriptorCount(for: folder) == 0 }
        XCTAssertEqual(
            Self.openDescriptorCount(for: folder), 0,
            "deinit must cancel the sources so their cancel handlers close the descriptors"
        )

        let noCallback = expectation(description: "no change callback after the watcher is gone")
        noCallback.isInverted = true
        counter.onRecord = { noCallback.fulfill() }
        try Data("two".utf8).write(to: folder.appendingPathComponent("two.txt"))
        await fulfillment(of: [noCallback], timeout: 1)
        XCTAssertEqual(counter.count, 1)
    }

    /// Counts this process's open descriptors whose path is `folder`. `F_GETPATH` reports the resolved path, so a
    /// temporary folder under `/var/folders/…` comes back as `/private/var/folders/…`; both spellings count.
    private static func openDescriptorCount(for folder: URL) -> Int {
        let folderPath = folder.standardizedFileURL.path
        let accepted: Set<String> = [folderPath, "/private" + folderPath]
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var count = 0
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if accepted.contains(path) { count += 1 }
        }
        return count
    }
}
