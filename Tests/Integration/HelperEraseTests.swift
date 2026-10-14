// Gated integration test: erase-on-quit (spec §4.3, §4.6) through a real shortcut bundle.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product Launcher
//   Tools/build-fixture.sh
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.HelperEraseTests
//
// Without MAD_INTEGRATION=1 the test is skipped. Like CLILaunchTests it runs the shortcut's executable directly
// (`Bundle.main` still resolves to the shortcut bundle) with HOME and CFFIXED_USER_HOME pointing at a temp home, so the
// Launcher's log, the helper and the fixture's HOME tree stay out of ~/Library. The Launcher starts the helper and execs
// the fixture, which quits after one second; the helper must then empty the data folder, keep the folder itself and
// leave the temp home's Desktop (linked into the HOME tree) untouched. The fixture window shows for about a second.

import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class HelperEraseTests: XCTestCase {
    struct Dump: Decodable {
        let homeDirectory: String
    }

    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var launcher: URL { root.appendingPathComponent(".build/release/Launcher") }
    private var fixture: URL { root.appendingPathComponent(".build/fixtures/FixtureApp.app") }
    private var fixtureBinary: URL { fixture.appendingPathComponent("Contents/MacOS/FixtureApp") }

    private let shortcutName = "MAD Helper Erase"
    private let fixtureBundleIdentifier = "com.mikekuta.appduplicator.fixture"

    // MARK: - Helpers (same shape as CLILaunchTests, whose helpers are private)

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
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    /// PIDs of every running process whose executable resolves to `executable`.
    private func pids(runningFrom executable: URL) -> Set<pid_t> {
        let target = resolved(executable)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = Int(filled) / MemoryLayout<pid_t>.size
        return Set(all.prefix(count).filter { $0 > 0 && resolved(processPath($0)) == target })
    }

    /// Kills anything still running from `executable` and waits until the process table is clear.
    private func reapLeftovers(runningFrom executable: URL) async throws {
        for pid in pids(runningFrom: executable) where kill(pid, SIGKILL) != 0 {
            XCTFail("kill(\(pid), SIGKILL) failed with errno \(errno)")
        }
        let deadline = Date().addingTimeInterval(5)
        while !pids(runningFrom: executable).isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Returns nil until the dump file exists. The fixture writes it atomically, so a present file is complete and a
    /// decode failure is a real error.
    private func loadDump(from url: URL) throws -> Dump? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Dump.self, from: Data(contentsOf: url))
    }

    /// Stops the Launcher-turned-fixture if it is somehow still running. `process` is this test's own child and is not
    /// reaped while it runs, so its pid cannot belong to anything else.
    private func stop(_ process: Process) async throws {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning, "The fixture did not stop after SIGTERM")
    }

    // MARK: - Tests

    func testEraseOnQuitEmptiesTheDataFolderAfterTheTargetQuits() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.isExecutableFile(atPath: fixtureBinary.path) else {
            XCTFail("Run: swift build -c release --product Launcher && Tools/build-fixture.sh")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        let dumpURL = tmp.appendingPathComponent("dump.json")
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let keep = desktop.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: keep)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let dataPath = ShortcutConfig.defaultDataPath(forSlug: slug, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataPath), "The data folder must not exist before the launch")
        let config = ShortcutConfig(
            kind: .app,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: fixture.path,
            targetBundleIdentifier: fixtureBundleIdentifier,
            launchMode: .dockShortcut,
            dataMode: .homeOverride,
            dataPath: dataPath,
            environment: ["MAD_FIXTURE_DUMP": dumpURL.path, "MAD_FIXTURE_LIFETIME": "1"],
            eraseOnQuit: true,
            menuBarIcon: false
        )
        let bundle = try BundleWriter().write(config: config, executable: launcher, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )

        // Teardown blocks run last-in-first-out: any helper or Launcher copy is reaped before the temp directory is
        // removed, including when the wait loop below throws. The fixture quits on its own after one second.
        addTeardownBlock { @MainActor [self] in
            try await reapLeftovers(runningFrom: executable)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        try process.run()

        // Collect everything first; assert only after every process is gone, so a failed assertion can never leave one
        // running. The Launcher execs into the fixture, so `process` runs until the fixture quits; the helper then
        // erases, logs `helper exit` and exits.
        var logText = ""
        let deadline = Date().addingTimeInterval(30)
        while (process.isRunning || !logText.contains(HelperLogLine.exiting) || !pids(runningFrom: executable).isEmpty)
            && Date() < deadline {
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let fixtureFinished = !process.isRunning
        let helperFinished = pids(runningFrom: executable).isEmpty
        try await stop(process)
        try await reapLeftovers(runningFrom: executable)

        if FileManager.default.fileExists(atPath: logURL.path) {
            logText = try String(contentsOf: logURL, encoding: .utf8)
        }
        let dump = try loadDump(from: dumpURL)
        // The helper logs the folder `EraseOnQuitPolicy` resolved, so the test resolves it the same way (the erase removed
        // the ownership marker too, so the policy would now refuse it).
        let folder = URL(fileURLWithPath: String(cString: realpath(dataPath, nil)), isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        XCTAssertTrue(fixtureFinished, "The fixture was still running after 30 s. Log: \(logText)")
        if fixtureFinished {
            XCTAssertEqual(process.terminationStatus, 0, "Log: \(logText)")
        }
        XCTAssertTrue(helperFinished, "A Launcher or helper process was still running after 30 s. Log: \(logText)")
        XCTAssertEqual(dump.map { resolved($0.homeDirectory) }, resolved(dataPath), "The fixture did not run with the data folder as HOME")
        let expectedLines = [
            "helper spawned pid=",
            "helper start pid=",
            HelperLogLine.execObserved,
            HelperLogLine.targetExited(waitStatus: 0),
            "helper erase \(folder.path) removed=",
            HelperLogLine.exiting,
        ]
        for expected in expectedLines {
            XCTAssertTrue(logText.contains(expected), "Missing \"\(expected)\" in the log: \(logText)")
        }
        XCTAssertFalse(logText.contains("failed="), "Log: \(logText)")
        XCTAssertFalse(logText.contains("helper erase skipped"), "Log: \(logText)")
        XCTAssertEqual(remaining, [], "The data folder still holds: \(remaining)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "The erase followed the Desktop link into the temp home")
    }
}
