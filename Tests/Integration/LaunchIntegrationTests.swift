// Gated integration tests: launch the fixture app through generated shortcut bundles.
//
// Prerequisites (run from the repo root):
//   swift build -c release
//   Tools/build-fixture.sh
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests
//
// Without MAD_INTEGRATION=1 every test is skipped. Each test opens the fixture
// window for about three seconds; that is expected.

import AppKit
import Foundation
import XCTest

@MainActor
final class LaunchIntegrationTests: XCTestCase {
    struct Dump: Decodable {
        let bundlePath: String
        let homeDirectory: String
        let arguments: [String]
        let environment: [String: String]
    }

    struct LaunchResult {
        let processPath: String
        let dump: Dump
    }

    // MARK: - Locations

    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var launcher: String { root.appendingPathComponent(".build/release/Launcher").path }
    private var madctl: String { root.appendingPathComponent(".build/release/madctl").path }
    private var fixture: URL { root.appendingPathComponent(".build/fixtures/FixtureApp.app") }

    private var tmp: URL?

    // MARK: - Helpers

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1",
            "Set MAD_INTEGRATION=1"
        )
        for path in [launcher, madctl, fixture.appendingPathComponent("Contents/MacOS/FixtureApp").path] {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: path),
                "Run: swift build -c release && Tools/build-fixture.sh"
            )
        }
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mad-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove \(directory.path): \(error)")
            }
        }
        tmp = directory
        return directory
    }

    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func resolved(_ path: String) -> String {
        resolved(URL(fileURLWithPath: path))
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    /// PIDs of every running process whose executable resolves to `executable`.
    /// `NSRunningApplication.processIdentifier` stays -1 for an app opened from a
    /// test runner without a GUI session, so the fixture's pid is found by path.
    private func pids(runningFrom executable: URL) -> Set<pid_t> {
        let target = resolved(executable)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = Int(filled) / MemoryLayout<pid_t>.size
        return Set(all.prefix(count).filter { $0 > 0 && resolved(processPath($0)) == target })
    }

    /// Runs `madctl new` for the fixture and returns the generated bundle URL.
    private func makeShortcut(name: String, extraArgs: [String]) throws -> URL {
        let tmp = try XCTUnwrap(self.tmp, "temp directory not created")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: madctl)
        process.arguments = [
            "new", fixture.path,
            "--name", name,
            "--launcher", launcher,
            "--out", tmp.appendingPathComponent("out").path,
            "--env", "MAD_FIXTURE_DUMP=\(tmp.appendingPathComponent("dump.json").path)",
        ] + extraArgs
        let stdout = Pipe()
        let stderrURL = tmp.appendingPathComponent("madctl-stderr.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderrHandle
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try stderrHandle.close()
        let errorText = try String(contentsOf: stderrURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, "madctl new failed: \(errorText)")
        let path = try XCTUnwrap(String(data: output, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(path.isEmpty, "madctl new printed no bundle path")
        return URL(fileURLWithPath: path)
    }

    /// Returns nil until the dump file exists. The fixture writes it atomically, so a
    /// present file is complete and a decode failure is a real error.
    private func loadDump(from url: URL) throws -> Dump? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Dump.self, from: Data(contentsOf: url))
    }

    private func terminate(_ app: NSRunningApplication) async throws {
        app.terminate()
        let graceDeadline = Date().addingTimeInterval(3)
        while !app.isTerminated && Date() < graceDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if !app.isTerminated {
            app.forceTerminate()
        }
        let finalDeadline = Date().addingTimeInterval(5)
        while !app.isTerminated && Date() < finalDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(app.isTerminated, "Fixture app did not terminate")
    }

    /// Opens the shortcut, waits for the fixture to write its dump, then terminates it.
    private func launchAndWaitForDump(bundle: URL) async throws -> LaunchResult {
        let tmp = try XCTUnwrap(self.tmp, "temp directory not created")
        let dumpURL = tmp.appendingPathComponent("dump.json")

        let fixtureBinary = fixture.appendingPathComponent("Contents/MacOS/FixtureApp")
        let preexisting = pids(runningFrom: fixtureBinary)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)

        var result: LaunchResult?
        var failure: Error?
        let deadline = Date().addingTimeInterval(10)
        while result == nil && failure == nil && Date() < deadline {
            do {
                if let dump = try loadDump(from: dumpURL) {
                    // The shortcut's Launcher execs the target, so the new process at the
                    // fixture's path is the launched app. Captured in the same iteration
                    // the dump first decodes, while the process is still alive.
                    let launched = pids(runningFrom: fixtureBinary).subtracting(preexisting)
                    let pid = try XCTUnwrap(launched.first, "No new FixtureApp process found")
                    XCTAssertEqual(launched.count, 1, "Expected exactly one new FixtureApp process: \(launched)")
                    result = LaunchResult(processPath: processPath(pid), dump: dump)
                    continue
                }
            } catch {
                failure = error
                continue
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        try await terminate(app)
        if let failure {
            throw failure
        }
        return try XCTUnwrap(
            result,
            "Fixture did not write \(dumpURL.path) within 10 s; see ~/Library/Logs/App Duplicator/"
        )
    }

    // MARK: - Tests

    func testHomeModeLaunchDumpsExpectedIdentity() async throws {
        try skipUnlessEnabled()
        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home")
        let bundle = try makeShortcut(
            name: "MAD Fixture Home",
            extraArgs: ["--data-mode", "home", "--data-path", home.path]
        )
        let result = try await launchAndWaitForDump(bundle: bundle)

        let expectedHome = resolved(home)
        let expectedBinary = resolved(fixture.appendingPathComponent("Contents/MacOS/FixtureApp"))
        XCTAssertEqual(resolved(result.processPath), expectedBinary)
        XCTAssertEqual(resolved(result.dump.homeDirectory), expectedHome)
        XCTAssertEqual(resolved(try XCTUnwrap(result.dump.environment["HOME"])), expectedHome)
        XCTAssertEqual(resolved(try XCTUnwrap(result.dump.environment["CFFIXED_USER_HOME"])), expectedHome)
        XCTAssertEqual(result.dump.environment["MAD_SHORTCUT_NAME"], "MAD Fixture Home")
        XCTAssertTrue(result.dump.bundlePath.hasSuffix("FixtureApp.app"), result.dump.bundlePath)
        var isDirectory: ObjCBool = false
        let support = home.appendingPathComponent("Library/Application Support").path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: support, isDirectory: &isDirectory) && isDirectory.boolValue,
            "Missing \(support)"
        )
    }

    func testLightAppearanceReachesTheTargetArguments() async throws {
        try skipUnlessEnabled()
        _ = try makeTempDirectory()
        let bundle = try makeShortcut(
            name: "MAD Fixture Light",
            extraArgs: ["--data-mode", "disabled", "--appearance", "light"]
        )
        let result = try await launchAndWaitForDump(bundle: bundle)

        let arguments = result.dump.arguments
        let flagIndex = try XCTUnwrap(
            arguments.firstIndex(of: "-NSRequiresAquaSystemAppearance"),
            "arguments: \(arguments)"
        )
        XCTAssertLessThan(flagIndex + 1, arguments.count, "flag has no value")
        if flagIndex + 1 < arguments.count {
            XCTAssertEqual(arguments[flagIndex + 1], "YES")
        }
        XCTAssertFalse(arguments.contains("-AppleInterfaceStyle"), "arguments: \(arguments)")
    }
}
