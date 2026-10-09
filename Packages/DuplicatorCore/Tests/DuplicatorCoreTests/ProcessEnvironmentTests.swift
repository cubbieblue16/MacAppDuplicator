import XCTest
@testable import DuplicatorCore

final class ProcessEnvironmentTests: XCTestCase {
    private let markerKey = "MAD_TEST_MARKER"
    private var children: [Process] = []

    override func tearDown() {
        for child in children where child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        children = []
        super.tearDown()
    }

    /// Starts a copy of `sleep` with `MAD_TEST_MARKER=<value>` in its environment and waits until the kernel reports
    /// the exec'd image's environment. `KERN_PROCARGS2` reflects the environment a process was started with
    /// (later `setenv` calls are not visible), so a child process is the only way to test a marker. The copy lives in
    /// a temporary directory because the kernel hides the environment of SIP-protected system binaries like `/bin/sleep`.
    private func spawnMarkedChild(value: String) throws -> pid_t {
        let directory = try makeTemporaryDirectory()
        let executable = directory.appending(path: "sleep-copy", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["60"]
        child.environment = ProcessInfo.processInfo.environment.merging([markerKey: value]) { _, new in new }
        try child.run()
        children.append(child)
        let pid = child.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if ProcessEnvironment.environment(ofProcess: pid)?[markerKey] == value { return pid }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("child \(pid) never reported \(markerKey)")
        return pid
    }

    func testReadsChildEnvironment() throws {
        let value = "marker-\(UUID().uuidString)"
        let pid = try spawnMarkedChild(value: value)

        let environment = try XCTUnwrap(ProcessEnvironment.environment(ofProcess: pid))

        XCTAssertEqual(environment[markerKey], value)
        XCTAssertNotNil(environment["PATH"])
    }

    func testReadsOwnEnvironment() throws {
        let environment = try XCTUnwrap(ProcessEnvironment.environment(ofProcess: getpid()))
        XCTAssertNotNil(environment["PATH"])
    }

    func testUnknownProcessReturnsNil() {
        // pid_t.max is never a live process id.
        XCTAssertNil(ProcessEnvironment.environment(ofProcess: pid_t.max))
    }

    func testAllProcessIDsContainsSelf() {
        XCTAssertTrue(ProcessEnvironment.allProcessIDs().contains(getpid()))
    }

    func testFindsProcessesByEnvironmentValue() throws {
        let value = "marker-\(UUID().uuidString)"
        let pid = try spawnMarkedChild(value: value)

        XCTAssertEqual(ProcessEnvironment.processIDs(whereEnvironment: markerKey, equals: value), [pid])
        XCTAssertEqual(ProcessEnvironment.values(forEnvironmentKey: markerKey)[pid], value)
        XCTAssertTrue(ProcessEnvironment.processIDs(whereEnvironment: markerKey, equals: "other").isEmpty)
    }
}
