import AppKit
import XCTest
@testable import MacAppDuplicator

extension LaunchEnvironmentTests {
    /// Guard test: the scene suppression below keys off this detection, so it must stay true inside the test host.
    func testTestHostDetectionHoldsInsideTheTestBundle() {
        XCTAssertTrue(LaunchEnvironment.isTestHost(), "the app's scenes are suppressed only when this is true under XCTest")
    }

    @MainActor
    func testTestHostOpensNoAutosavingWindow() async throws {
        // Let SwiftUI finish materializing its launch scenes before looking.
        try await Task.sleep(for: .milliseconds(500))
        let autosaving = NSApp.windows.map(\.frameAutosaveName).filter { !$0.isEmpty }
        XCTAssertEqual(
            autosaving, [],
            "the test host must open no window; a window's frame autosave writes the real com.mikekuta.MacAppDuplicator defaults (re-review Minor 7)"
        )
    }
}
