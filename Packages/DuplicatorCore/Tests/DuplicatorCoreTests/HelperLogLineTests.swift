import XCTest
@testable import DuplicatorCore

final class HelperLogLineTests: XCTestCase {
    func testLifecycleAndMenuLines() {
        XCTAssertEqual(
            HelperLogLine.start(helperPID: 501, watchedPID: 500, bundlePath: "/Apps/Claude Work.app", dataPath: "/Users/t/data"),
            "helper start pid=501 watch=500 bundle=/Apps/Claude Work.app data=/Users/t/data"
        )
        XCTAssertEqual(
            HelperLogLine.start(helperPID: 501, watchedPID: 500, bundlePath: "/Apps/Claude Work.app", dataPath: nil),
            "helper start pid=501 watch=500 bundle=/Apps/Claude Work.app data=-"
        )
        XCTAssertEqual(HelperLogLine.malformed(argumentCount: 3), "helper malformed argv argc=3")
        XCTAssertEqual(HelperLogLine.execObserved, "helper exec observed")
        XCTAssertEqual(HelperLogLine.watchedProcessGone, "helper watched process already gone")
        XCTAssertEqual(HelperLogLine.watchFailed("kevent errno=9"), "helper watch failed: kevent errno=9")
        XCTAssertEqual(
            HelperLogLine.newWindow(argv: ["/usr/bin/env", "open", "--args", "--api-key=abc", "--token", "t"]),
            "helper new window argv /usr/bin/env open --args --api-key=•••••• --token ••••••"
        )
        XCTAssertEqual(HelperLogLine.newWindowFailed("posix_spawn errno=2"), "helper new window failed: posix_spawn errno=2")
        XCTAssertEqual(HelperLogLine.quit(signal: SIGTERM), "helper quit signal=15")
        XCTAssertEqual(HelperLogLine.showFailed("pid 500 is not an application"), "helper show failed: pid 500 is not an application")
        XCTAssertEqual(HelperLogLine.spawned(pid: 502), "helper spawned pid=502")
        XCTAssertEqual(
            HelperLogLine.spawnFailed("Could not start /x: No such file or directory"),
            "helper spawn failed: Could not start /x: No such file or directory"
        )
        XCTAssertEqual(HelperLogLine.exiting, "helper exit")
    }

    func testExitStatusAndEraseLines() {
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: 7 << 8), "helper target exited status=7")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: 0), "helper target exited status=0")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: SIGKILL), "helper target exited status=137")
        XCTAssertEqual(HelperLogLine.targetExited(waitStatus: nil), "helper target exited status=unavailable")
        XCTAssertEqual(HelperLogLine.launcherFailed(waitStatus: 3 << 8), "helper launcher exited before exec status=3")
        XCTAssertEqual(HelperLogLine.pidReused, "helper watched pid was reused")
        XCTAssertEqual(HelperLogLine.erased(path: "/Users/t/data", removed: 4, failed: 0), "helper erase /Users/t/data removed=4")
        XCTAssertEqual(
            HelperLogLine.erased(path: "/Users/t/data", removed: 4, failed: 2),
            "helper erase /Users/t/data removed=4 failed=2"
        )
        XCTAssertEqual(HelperLogLine.eraseSkipped("the path is a symbolic link"), "helper erase skipped: the path is a symbolic link")
        XCTAssertEqual(HelperLogLine.dataPathMismatch, "helper erase skipped: the data path does not match MADConfig")
        XCTAssertEqual(
            HelperLogLine.otherCopiesRunning(pids: [41, 42]),
            "helper erase skipped: another copy of this shortcut is still running (pid 41,42)"
        )
        XCTAssertEqual(HelperLogLine.ownPathUnreadable, "helper erase skipped: the helper cannot read its own executable path")
    }
}
