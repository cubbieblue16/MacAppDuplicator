import XCTest
@testable import DuplicatorCore

final class HelperWatchStateTests: XCTestCase {
    private let launcher = "/Users/test/Applications/App Duplicator/Notes Work.app/Contents/MacOS/Notes Work"
    private let target = "/System/Applications/Notes.app/Contents/MacOS/Notes"

    func testAnExecThenAnExitIsATargetExit() {
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertFalse(state.execObserved)
        XCTAssertEqual(state.apply(.exec, startTime: .same), .keepWatching)
        XCTAssertTrue(state.execObserved)
        XCTAssertEqual(state.apply(.exit(waitStatus: 0), startTime: .gone), .targetExited(waitStatus: 0))
    }

    func testAnExitWithoutAnExecIsALauncherFailure() {
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(state.apply(.exit(waitStatus: 3 << 8), startTime: .gone), .launcherFailed(waitStatus: 3 << 8))
        var withoutStatus = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(withoutStatus.apply(.exit(waitStatus: nil), startTime: .different), .launcherFailed(waitStatus: nil))
    }

    func testAnExecBeforeTheWatchStartedIsReadFromTheExecutablePaths() {
        XCTAssertTrue(HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: launcher).execObserved)
        XCTAssertFalse(HelperWatchState(requiresExec: true, parentExecutablePath: nil, ownExecutablePath: launcher).execObserved)
        XCTAssertFalse(HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: nil).execObserved)
        var state = HelperWatchState(requiresExec: true, parentExecutablePath: target, ownExecutablePath: launcher)
        XCTAssertEqual(state.apply(.exit(waitStatus: 0), startTime: .gone), .targetExited(waitStatus: 0))
    }

    func testSystemLaunchWatchesTheTargetWithoutAnExec() {
        var state = HelperWatchState(requiresExec: false, parentExecutablePath: nil, ownExecutablePath: nil)
        XCTAssertTrue(state.execObserved)
        XCTAssertEqual(state.apply(.exit(waitStatus: SIGKILL), startTime: .gone), .targetExited(waitStatus: SIGKILL))
    }

    func testTheStartupDecisionFollowsTheStartTime() {
        XCTAssertEqual(HelperWatchState.startupDecision(for: .same), .keepWatching)
        XCTAssertEqual(HelperWatchState.startupDecision(for: .different), .pidReused)
        XCTAssertEqual(HelperWatchState.startupDecision(for: .gone), .watchedProcessGone)
    }

    func testAnExecFromAReusedPidIsRefusedButAnExecThatRacesTheExitCounts() {
        var reused = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(reused.apply(.exec, startTime: .different), .pidReused)
        XCTAssertFalse(reused.execObserved)
        var raced = HelperWatchState(requiresExec: true, parentExecutablePath: launcher, ownExecutablePath: launcher)
        XCTAssertEqual(raced.apply(.exec, startTime: .gone), .keepWatching)
        XCTAssertEqual(raced.apply(.exit(waitStatus: nil), startTime: .gone), .targetExited(waitStatus: nil))
    }
}
