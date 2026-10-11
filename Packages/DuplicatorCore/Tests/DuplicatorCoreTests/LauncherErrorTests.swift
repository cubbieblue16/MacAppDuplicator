import XCTest
@testable import DuplicatorCore

final class LauncherErrorTests: XCTestCase {
    func testMessagesCarryTheDetailsTheAlertShows() {
        XCTAssertEqual(
            LauncherError.configMissing.errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        )
        XCTAssertEqual(
            LauncherError.configCorrupt("bad engineVersion").errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (bad engineVersion)"
        )
        XCTAssertEqual(
            LauncherError.targetNotFound(path: "/Applications/Claude.app", bundleID: "com.anthropic.claudefordesktop").errorDescription,
            "The target app was not found.\nStored path: /Applications/Claude.app\nBundle ID: com.anthropic.claudefordesktop"
        )
        XCTAssertEqual(LauncherError.dataPathNotWritable("/data").errorDescription, "The data folder is not writable: /data")
        XCTAssertEqual(
            LauncherError.execFailed(errno: ENOENT, path: "/Applications/X.app/Contents/MacOS/X").errorDescription,
            "Could not start /Applications/X.app/Contents/MacOS/X: No such file or directory"
        )
        XCTAssertEqual(LauncherError.notAnAppBundle("/tmp/X.app").errorDescription, "/tmp/X.app is not a valid application bundle.")
    }

    func testExitCodesFollowTheErrorTable() {
        XCTAssertEqual(LauncherError.configMissing.exitCode, 1)
        XCTAssertEqual(LauncherError.configCorrupt("x").exitCode, 1)
        XCTAssertEqual(LauncherError.targetNotFound(path: "/x", bundleID: "y").exitCode, 2)
        XCTAssertEqual(LauncherError.notAnAppBundle("/x").exitCode, 2)
        XCTAssertEqual(LauncherError.execFailed(errno: EACCES, path: "/x").exitCode, 3)
        XCTAssertEqual(LauncherError.dataPathNotWritable("/x").exitCode, 4)
    }

    func testLauncherKindMessages() {
        XCTAssertEqual(
            LauncherError.fileNotFound(path: "/Users/test/Notes.md").errorDescription,
            "The file, folder or command was not found.\nStored path: /Users/test/Notes.md"
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.terminal).errorDescription,
            "Terminal is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.iterm2).errorDescription,
            "iTerm2 is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(.ghostty).errorDescription,
            "Ghostty is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.terminalNotFound(TerminalChoice.none).errorDescription,
            "The selected terminal is not installed. Choose another terminal in macOS App Duplicator."
        )
        XCTAssertEqual(
            LauncherError.spawnFailed(errno: EACCES, path: "/usr/local/bin/tool").errorDescription,
            "Could not start /usr/local/bin/tool: Permission denied"
        )
        XCTAssertEqual(
            LauncherError.launcherConfigMissing(.cli).errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The cli settings are missing.)"
        )
        XCTAssertEqual(
            LauncherError.launcherConfigMissing(.folder).errorDescription,
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The folder settings are missing.)"
        )
    }

    func testLauncherKindExitCodes() {
        XCTAssertEqual(LauncherError.launcherConfigMissing(.file).exitCode, 1)
        XCTAssertEqual(LauncherError.fileNotFound(path: "/x").exitCode, 2)
        XCTAssertEqual(LauncherError.spawnFailed(errno: ENOENT, path: "/x").exitCode, 3)
        XCTAssertEqual(LauncherError.terminalNotFound(.ghostty).exitCode, 5)
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(status: 1, stderr: "x", terminal: .terminal, bundleIdentifier: "y").exitCode,
            3
        )
    }

    func testTerminalScriptFailedShowsTheTrimmedErrorOutput() {
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(
                status: 1,
                stderr: "  0:5: syntax error: Expected end of line but found identifier. (-2741)\n",
                terminal: .terminal,
                bundleIdentifier: "com.mikekuta.appduplicator.projects"
            ).errorDescription,
            "The terminal could not be opened (osascript exit 1). 0:5: syntax error: Expected end of line but found identifier. (-2741)"
        )
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(
                status: 134,
                stderr: " \n",
                terminal: .iterm2,
                bundleIdentifier: "com.mikekuta.appduplicator.projects"
            ).errorDescription,
            "The terminal could not be opened (osascript exit 134)."
        )
    }

    func testTerminalScriptFailedAddsTheAutomationHintWhenAppleEventsAreDenied() {
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(
                status: 1,
                stderr: "36:186: execution error: Not authorized to send Apple events to Terminal. (-1743)\n",
                terminal: .terminal,
                bundleIdentifier: "com.mikekuta.appduplicator.projects"
            ).errorDescription,
            "The terminal could not be opened (osascript exit 1). 36:186: execution error: Not authorized to send Apple events"
                + " to Terminal. (-1743) Allow the shortcut to control Terminal in System Settings > Privacy & Security"
                + " > Automation, or reset with: tccutil reset AppleEvents com.mikekuta.appduplicator.projects"
        )
        // Either marker alone is enough: the error number without the English text, and the text without the number.
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(
                status: 1,
                stderr: "execution error: (-1743)",
                terminal: .iterm2,
                bundleIdentifier: "com.mikekuta.appduplicator.work"
            ).errorDescription,
            "The terminal could not be opened (osascript exit 1). execution error: (-1743) Allow the shortcut to control"
                + " iTerm2 in System Settings > Privacy & Security > Automation, or reset with: tccutil reset AppleEvents"
                + " com.mikekuta.appduplicator.work"
        )
        XCTAssertEqual(
            LauncherError.terminalScriptFailed(
                status: 1,
                stderr: "Not authorized to send Apple events to iTerm2.",
                terminal: .iterm2,
                bundleIdentifier: "com.mikekuta.appduplicator.work"
            ).errorDescription,
            "The terminal could not be opened (osascript exit 1). Not authorized to send Apple events to iTerm2. Allow the"
                + " shortcut to control iTerm2 in System Settings > Privacy & Security > Automation, or reset with: tccutil"
                + " reset AppleEvents com.mikekuta.appduplicator.work"
        )
    }
}
