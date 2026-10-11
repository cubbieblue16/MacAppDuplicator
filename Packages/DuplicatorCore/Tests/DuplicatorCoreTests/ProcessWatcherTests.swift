import Darwin
import XCTest
@testable import DuplicatorCore

/// Every test watches a short-lived child it starts and reaps itself. `/bin/sh` is a trampoline that execs the selected
/// shell (one extra exec event), so the scripts run under `/bin/bash` directly.
final class ProcessWatcherTests: XCTestCase {
    private func start(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    /// Every event until the first `.exit`, waiting at most 10 s in all.
    private func eventsUntilExit(_ watcher: ProcessWatcher) throws -> [ProcessWatchEvent] {
        var events: [ProcessWatchEvent] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            events += try watcher.wait(timeout: 1)
            if case .exit? = events.last {
                break
            }
        }
        return events
    }

    func testReportsTheExitStatusOfAChild() throws {
        let process = try start("/bin/bash", ["-c", "sleep 0.3; exit 3"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(watcher.pid, process.processIdentifier)
        XCTAssertTrue(watcher.reportsExitStatus)
        XCTAssertEqual(try eventsUntilExit(watcher), [.exit(waitStatus: 3 << 8)])
    }

    func testReportsAnExecBeforeTheExit() throws {
        let process = try start("/bin/bash", ["-c", "/bin/sleep 0.3; exec /bin/sleep 0.3"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(try eventsUntilExit(watcher), [.exec, .exit(waitStatus: 0)])
    }

    func testAMissingProcessIsReportedAsGone() {
        XCTAssertThrowsError(try ProcessWatcher(pid: Int32.max)) { error in
            XCTAssertEqual(error as? ProcessWatcherError, .processGone)
        }
        XCTAssertThrowsError(try ProcessWatcher(pid: 0)) { error in
            XCTAssertEqual(error as? ProcessWatcherError, .processGone)
        }
    }

    func testATimeoutReturnsNoEventsAndASignalExitIsReported() throws {
        let process = try start("/bin/sleep", ["30"])
        defer { stop(process) }
        let watcher = try ProcessWatcher(pid: process.processIdentifier)
        XCTAssertEqual(try watcher.wait(timeout: 0.2), [])
        XCTAssertEqual(try watcher.wait(timeout: 0), [])
        process.terminate()
        XCTAssertEqual(try eventsUntilExit(watcher), [.exit(waitStatus: SIGTERM)])
    }

    func testExecutablePathsAndProcessListsComeFromTheKernel() throws {
        let process = try start("/bin/sleep", ["5"])
        defer { stop(process) }
        XCTAssertEqual(ProcessWatcher.executablePath(of: process.processIdentifier), "/bin/sleep")
        XCTAssertNil(ProcessWatcher.executablePath(of: Int32.max))
        XCTAssertTrue(ProcessWatcher.pids(runningFrom: "/bin/sleep").contains(process.processIdentifier))
        XCTAssertEqual(ProcessWatcher.pids(runningFrom: "/nonexistent/\(UUID().uuidString)"), [])
    }
}
