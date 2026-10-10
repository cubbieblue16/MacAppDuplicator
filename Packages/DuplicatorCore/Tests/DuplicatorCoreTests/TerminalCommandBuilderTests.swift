import XCTest
@testable import DuplicatorCore

final class TerminalCommandBuilderTests: XCTestCase {
    private let terminalApp = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
    private let iTermApp = URL(filePath: "/Applications/iTerm.app", directoryHint: .isDirectory)
    private let ghosttyApp = URL(filePath: "/Applications/Ghostty.app", directoryHint: .isDirectory)

    func testShellQuotedWrapsEveryElementAndEscapesSingleQuotes() {
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted(["/bin/echo", "a b", "it's"]), #"'/bin/echo' 'a b' 'it'\''s'"#)
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted(["$HOME", "`x`", ""]), #"'$HOME' '`x`' ''"#)
        XCTAssertEqual(TerminalCommandBuilder.shellQuoted([]), "")
    }

    func testAppleScriptLiteralEscapesBackslashesBeforeQuotes() {
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral(#"say "hi" \n"#), #""say \"hi\" \\n""#)
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral(#"\""#), #""\\\"""#)
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral("plain"), #""plain""#)
    }

    func testTerminalScriptWithAndWithoutWorkingDirectory() {
        XCTAssertEqual(
            TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top' '-o' 'cpu'", workingDirectory: nil),
            #"""
            tell application "Terminal"
                activate
                do script "'/usr/bin/top' '-o' 'cpu'"
            end tell
            """#
        )
        XCTAssertEqual(
            TerminalCommandBuilder.terminalScript(command: "'/bin/ls'", workingDirectory: #"/Users/test/My "Dir""#),
            #"""
            tell application "Terminal"
                activate
                do script "cd '/Users/test/My \"Dir\"' && '/bin/ls'"
            end tell
            """#
        )
    }

    func testITermScriptWithAndWithoutWorkingDirectory() {
        XCTAssertEqual(
            TerminalCommandBuilder.iTermScript(command: "'/usr/bin/top'", workingDirectory: nil),
            #"""
            tell application "iTerm2"
                activate
                create window with default profile command "'/usr/bin/top'"
            end tell
            """#
        )
        XCTAssertEqual(
            TerminalCommandBuilder.iTermScript(command: "'/usr/bin/top'", workingDirectory: "/Users/test/it's"),
            #"""
            tell application "iTerm2"
                activate
                create window with default profile command "cd '/Users/test/it'\\''s' && '/usr/bin/top'"
            end tell
            """#
        )
    }

    func testArgvForNoneIsTheCommandItself() throws {
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], workingDirectory: "/tmp", terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder().argv(for: cli, terminalApp: nil, inlineEnvironment: [:]), ["/bin/sh", "-c", "echo hi"])
    }

    func testArgvForTerminalRunsOsascriptWithTheTerminalScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: "~/Projects", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        let script = TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top' '-o' 'cpu'", workingDirectory: NSHomeDirectory() + "/Projects")
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", script])
        XCTAssertTrue(argv[2].contains("do script \"cd '\(NSHomeDirectory())/Projects' && '/usr/bin/top' '-o' 'cpu'\""), argv[2])
    }

    func testArgvForITermRunsOsascriptWithTheITermScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/ssh", arguments: ["it's"], terminal: .iterm2)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: #"'/usr/bin/ssh' 'it'\''s'"#, workingDirectory: nil)])
        XCTAssertTrue(argv[2].contains(#"create window with default profile command "'/usr/bin/ssh' 'it'\\''s'""#), argv[2])
    }

    func testArgvForGhosttyRunsTheGhosttyBinaryWithDashE() throws {
        let cli = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], workingDirectory: "/tmp", terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder().argv(for: cli, terminalApp: ghosttyApp, inlineEnvironment: [:]),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }

    func testArgvThrowsTerminalNotFoundWhenTheTerminalAppIsMissing() {
        for choice in [TerminalChoice.terminal, TerminalChoice.iterm2, TerminalChoice.ghostty] {
            let cli = CLIConfig(executablePath: "/bin/ls", terminal: choice)
            XCTAssertThrowsError(try TerminalCommandBuilder().argv(for: cli, terminalApp: nil, inlineEnvironment: [:])) { error in
                guard case LauncherError.terminalNotFound(let reported) = error else {
                    return XCTFail("expected terminalNotFound, got \(error)")
                }
                XCTAssertEqual(reported, choice)
            }
        }
    }

    // MARK: Inline environment (Terminal.app and iTerm2 start a fresh login shell, so the environment goes into the command)

    func testTerminalAndITermWriteTheSortedEnvironmentAfterUsrBinEnv() throws {
        let environment = ["MAD_SHORTCUT_NAME": "Top", "HOME": "/Users/test/own", "A_FIRST": "1"]
        let command = "/usr/bin/env 'A_FIRST=1' 'HOME=/Users/test/own' 'MAD_SHORTCUT_NAME=Top' '/usr/bin/top' '-o' 'cpu'"
        var cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: "/tmp", terminal: .terminal)

        let terminalArgv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: environment)
        XCTAssertEqual(terminalArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: command, workingDirectory: "/tmp")])
        XCTAssertTrue(terminalArgv[2].contains("do script \"cd '/tmp' && /usr/bin/env 'A_FIRST=1' 'HOME=/Users/test/own'"), terminalArgv[2])

        cli.terminal = .iterm2
        let iTermArgv = try TerminalCommandBuilder().argv(for: cli, terminalApp: iTermApp, inlineEnvironment: environment)
        XCTAssertEqual(iTermArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: command, workingDirectory: "/tmp")])
    }

    func testInlineEnvironmentValueWithSpaceAndSingleQuoteIsQuoted() throws {
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: ["GREETING": "it's a test"])
        XCTAssertEqual(
            argv,
            ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: #"/usr/bin/env 'GREETING=it'\''s a test' '/bin/ls'"#, workingDirectory: nil)]
        )
        XCTAssertTrue(argv[2].contains(#"do script "/usr/bin/env 'GREETING=it'\\''s a test' '/bin/ls'""#), argv[2])
    }

    func testEmptyInlineEnvironmentAddsNoEnvPrefix() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal)
        let argv = try TerminalCommandBuilder().argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top'", workingDirectory: nil)])
        XCTAssertFalse(argv[2].contains("/usr/bin/env"), argv[2])
    }

    func testNoTerminalAndGhosttyIgnoreTheInlineEnvironment() throws {
        let environment = ["HOME": "/Users/test/own", "MAD_SHORTCUT_NAME": "Top"]
        let plain = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder().argv(for: plain, terminalApp: nil, inlineEnvironment: environment), ["/bin/sh", "-c", "echo hi"])
        let ghostty = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder().argv(for: ghostty, terminalApp: ghosttyApp, inlineEnvironment: environment),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }
}
