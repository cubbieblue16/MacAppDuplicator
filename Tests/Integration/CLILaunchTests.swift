// Gated integration test: run a command shortcut whose executable is the Launcher binary.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product Launcher
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.CLILaunchTests
//
// Without MAD_INTEGRATION=1 the test is skipped. The shortcut runs `/bin/sh -c 'env > "$MAD_FIXTURE_DUMP"'` with
// `TerminalChoice.none`, so no terminal app opens and nothing runs osascript. The Launcher exits as soon as the
// command is spawned and never checks in with LaunchServices as an app, so the test runs the bundle's executable
// directly (`Bundle.main` still resolves to the shortcut bundle) and asserts its exit status. HOME and
// CFFIXED_USER_HOME point at a temp directory, so the Launcher's log and the command's HOME tree stay out of ~/Library.

import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class CLILaunchTests: XCTestCase {
    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var launcher: URL { root.appendingPathComponent(".build/release/Launcher") }

    private let shortcutName = "MAD CLI Smoke"

    /// What `/bin/sh` may be once it has exec'd: macOS ships `/bin/sh` as a shim that re-execs the selected shell.
    private let shellPaths: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash"]

    // MARK: - Helpers (same shape as WebShellLaunchTests)

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

    /// The pid from the Launcher's `spawned pid=<n>` log line, or nil before that line is written.
    private func spawnedPID(in logText: String) -> pid_t? {
        for line in logText.split(separator: "\n") {
            if let range = line.range(of: "spawned pid=") {
                return pid_t(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Kills the spawned shell if it is somehow still alive. The pid is only signalled while it still belongs to a
    /// shell binary, so a recycled pid is never touched.
    private func reapShell(_ pid: pid_t?) async throws {
        guard let pid else { return }
        let deadline = Date().addingTimeInterval(5)
        while shellPaths.contains(resolved(processPath(pid))) && Date() < deadline {
            if kill(pid, SIGKILL) != 0 && errno != ESRCH {
                XCTFail("kill(\(pid), SIGKILL) failed with errno \(errno)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `KEY=VALUE` lines from `env`; a line without `=` (a multi-line value's continuation) is skipped.
    private func parseEnvironment(_ text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return environment
    }

    // MARK: - Tests

    func testDetachedCommandShortcutRunsWithTheShortcutEnvironment() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            XCTFail("Run: swift build -c release --product Launcher")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        let dump = tmp.appendingPathComponent("env.txt")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let config = ShortcutConfig(
            kind: .cli,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            environment: ["MAD_FIXTURE_DUMP": dump.path],
            cli: CLIConfig(
                executablePath: "/bin/sh",
                arguments: ["-c", "env > \"$MAD_FIXTURE_DUMP\""],
                terminal: TerminalChoice.none,
                homeOverride: true
            )
        )
        let bundle = try BundleWriter().write(config: config, executable: launcher, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )
        let expectedHome = resolved(ShortcutConfig.defaultDataPath(forSlug: slug, home: home))

        // Teardown blocks run last-in-first-out: the shell and any Launcher copy are reaped before the temp
        // directory is removed, including when the wait loop below throws.
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

        // Collect everything first; assert only after every process is gone, so a failed assertion can never leave
        // one running.
        var logText = ""
        var dumpText = ""
        let deadline = Date().addingTimeInterval(10)
        while (process.isRunning || !logText.contains("exit 0") || !dumpText.contains("MAD_SHORTCUT_NAME=")) && Date() < deadline {
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            if FileManager.default.fileExists(atPath: dump.path) {
                dumpText = try String(contentsOf: dump, encoding: .utf8)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let launcherFinished = !process.isRunning
        let shellPID = spawnedPID(in: logText)

        if !launcherFinished {
            process.terminate()
        }
        try await reapShell(shellPID)
        try await reapLeftovers(runningFrom: executable)

        XCTAssertTrue(launcherFinished, "The Launcher was still running after 10 s. Log: \(logText)")
        if launcherFinished {
            XCTAssertEqual(process.terminationStatus, 0, "Launcher log: \(logText)")
        }
        XCTAssertNotNil(shellPID, "No spawned pid line. Log: \(logText)")
        XCTAssertTrue(logText.contains("kind cli"), "Launcher log: \(logText)")
        XCTAssertTrue(logText.contains("spawn /bin/sh argc=3 terminal=none"), "Launcher log: \(logText)")
        XCTAssertTrue(logText.contains("exit 0"), "Launcher log: \(logText)")
        XCTAssertFalse(logText.contains("osascript"), "Launcher log: \(logText)")

        let dumped = parseEnvironment(dumpText)
        XCTAssertEqual(dumped["MAD_SHORTCUT_NAME"], shortcutName)
        XCTAssertEqual(dumped["MAD_SHORTCUT_BUNDLE"].map(resolved), resolved(bundle))
        XCTAssertEqual(dumped["MAD_FIXTURE_DUMP"], dump.path)
        XCTAssertNil(dumped["MAD_INTEGRATION"], "MAD_* variables from the Launcher's own environment must not reach the command")
        XCTAssertEqual(dumped["HOME"].map(resolved), expectedHome)
        XCTAssertEqual(dumped["CFFIXED_USER_HOME"].map(resolved), expectedHome)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedHome + "/" + HomeTreeBuilder.markerFileName),
            "HOME tree not built at \(expectedHome)"
        )
        XCTAssertTrue(pids(runningFrom: executable).isEmpty, "A Launcher process was left running")
    }
}
