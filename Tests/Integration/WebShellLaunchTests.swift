// Gated integration test: launch a web-app shortcut whose executable is the WebShell binary.
//
// Prerequisites (run from the repo root):
//   swift build -c release --product WebShell
//   MAD_INTEGRATION=1 swift test --filter IntegrationTests.WebShellLaunchTests
//
// Without MAD_INTEGRATION=1 the test is skipped. The shortcut points at https://example.invalid (a reserved
// name that never resolves), so the page load fails and the inline error view shows; the test asserts process
// identity and the shell's start log only. A window opens for a few seconds; that is expected. HOME and
// CFFIXED_USER_HOME point at a temp directory so the shell's log, defaults and web data stay out of ~/Library.

import AppKit
import DuplicatorCore
import Foundation
import XCTest

@MainActor
final class WebShellLaunchTests: XCTestCase {
    /// Repo root: three directories above `Tests/Integration/<this file>`.
    private let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private var webShell: URL { root.appendingPathComponent(".build/release/WebShell") }

    private let shortcutName = "MAD WebShell Smoke"

    // MARK: - Helpers (same shape as LaunchIntegrationTests)

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
    /// `NSRunningApplication.processIdentifier` stays -1 for an app opened from a
    /// test runner without a GUI session, so the shell's pid is found by path.
    private func pids(runningFrom executable: URL) -> Set<pid_t> {
        let target = resolved(executable)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let count = Int(filled) / MemoryLayout<pid_t>.size
        return Set(all.prefix(count).filter { $0 > 0 && resolved(processPath($0)) == target })
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
        XCTAssertTrue(app.isTerminated, "WebShell shortcut did not terminate")
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

    // MARK: - Tests

    func testWebAppShortcutLaunchesUnderItsOwnBundleIdentity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAD_INTEGRATION"] == "1", "Set MAD_INTEGRATION=1")
        guard FileManager.default.isExecutableFile(atPath: webShell.path) else {
            XCTFail("Run: swift build -c release --product WebShell")
            return
        }

        let tmp = try makeTempDirectory()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let output = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let slug = ShortcutConfig.slug(for: shortcutName)
        let config = ShortcutConfig(
            kind: .webApp,
            name: shortcutName,
            slug: slug,
            bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
            targetPath: "",
            targetBundleIdentifier: "",
            launchMode: .dockShortcut,
            dataMode: .disabled,
            webApp: WebAppConfig(url: "https://example.invalid")
        )
        let bundle = try BundleWriter().write(config: config, executable: webShell, iconFile: nil, to: output)
        try Signer().sign(bundle: bundle, identity: nil)
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL, "Shortcut bundle has no executable")
        let logURL = home.appendingPathComponent(
            "Library/Logs/App Duplicator/\(ShortcutConfig.fileSystemName(for: shortcutName)).log"
        )

        // Teardown blocks run last-in-first-out: the reap registered below runs before this domain removal,
        // so the shell cannot rewrite its preferences plist after it is cleared. Only the shortcut's own
        // domain is touched.
        let shortcutDomain = config.bundleIdentifier
        addTeardownBlock {
            UserDefaults(suiteName: shortcutDomain)?.removePersistentDomain(forName: shortcutDomain)
            CFPreferencesAppSynchronize(shortcutDomain as CFString)
            // Clearing the domain leaves an empty plist that cfprefsd flushes asynchronously; let that
            // flush land, then remove that one file.
            try await Task.sleep(for: .milliseconds(500))
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(shortcutDomain).plist")
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
            }
        }
        // Always terminate and reap the launched shell, including when the wait loop below throws.
        addTeardownBlock { @MainActor [self] in
            try await reapLeftovers(runningFrom: executable)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)

        // Collect everything while the shell is alive; assert only after it has been terminated so a
        // failed assertion can never leave the process running.
        var launched: Set<pid_t> = []
        var logText = ""
        let expectedConfigLine = "config name=\(shortcutName) host=example.invalid"
        let deadline = Date().addingTimeInterval(10)
        while (launched.isEmpty || !logText.contains(expectedConfigLine)) && Date() < deadline {
            launched = pids(runningFrom: executable)
            if FileManager.default.fileExists(atPath: logURL.path) {
                logText = try String(contentsOf: logURL, encoding: .utf8)
            }
            if launched.isEmpty || !logText.contains(expectedConfigLine) {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let runningBundleIdentifier = app.bundleIdentifier
        let runningPID = app.processIdentifier
        let launchedPath = launched.first.map(processPath) ?? ""

        try await terminate(app)
        try await reapLeftovers(runningFrom: executable)

        if let runningBundleIdentifier {
            XCTAssertEqual(runningBundleIdentifier, config.bundleIdentifier)
        }
        XCTAssertEqual(launched.count, 1, "Expected exactly one WebShell process: \(launched)")
        XCTAssertEqual(resolved(launchedPath), resolved(executable))
        if runningPID > 0 {
            XCTAssertEqual(launched, [runningPID])
        }
        XCTAssertTrue(logText.contains("start pid="), "Shell log: \(logText)")
        XCTAssertTrue(logText.contains(expectedConfigLine), "Shell log: \(logText)")
        XCTAssertFalse(logText.contains("exit 2"), "Shell rejected its MADConfig: \(logText)")
        XCTAssertTrue(pids(runningFrom: executable).isEmpty, "A WebShell process was left running")
    }
}
