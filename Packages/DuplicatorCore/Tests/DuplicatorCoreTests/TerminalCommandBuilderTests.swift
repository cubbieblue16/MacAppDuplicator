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
                create window with default profile
                tell current session of current window
                    write text "'/usr/bin/top'"
                end tell
            end tell
            """#
        )
        XCTAssertEqual(
            TerminalCommandBuilder.iTermScript(command: "'/usr/bin/top'", workingDirectory: "/Users/test/it's"),
            #"""
            tell application "iTerm2"
                activate
                create window with default profile
                tell current session of current window
                    write text "cd '/Users/test/it'\\''s' && '/usr/bin/top'"
                end tell
            end tell
            """#
        )
    }

    func testITermWriteTextKeepsInterpolationSyntaxAndSingleQuotesApartFromTheDocumentedEscapes() throws {
        let cli = CLIConfig(executablePath: "/bin/echo", arguments: [#"\(x)"#, "it's"], workingDirectory: "/tmp", terminal: .iterm2)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])
        let shellCommand = #"cd '/tmp' && '/bin/echo' '\(x)' 'it'\''s'"#
        let quoted = TerminalCommandBuilder.shellQuoted(["/bin/echo", #"\(x)"#, "it's"])
        XCTAssertEqual(TerminalCommandBuilder.shellCommand(quoted, workingDirectory: "/tmp"), shellCommand)
        // Only the documented escapes apply: each backslash is doubled (there are no double quotes here); `(x)` and
        // every single quote pass through byte for byte.
        let literal = #""cd '/tmp' && '/bin/echo' '\\(x)' 'it'\\''s'""#
        XCTAssertEqual(TerminalCommandBuilder.appleScriptLiteral(shellCommand), literal)
        XCTAssertEqual(literal.replacingOccurrences(of: #"\\"#, with: #"\"#), "\"" + shellCommand + "\"")
        XCTAssertTrue(argv[2].contains("write text " + literal), argv[2])
        XCTAssertFalse(argv[2].contains("profile command"), argv[2])
    }

    func testArgvForNoneIsTheCommandItself() throws {
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], workingDirectory: "/tmp", terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: nil, inlineEnvironment: [:]), ["/bin/sh", "-c", "echo hi"])
    }

    func testArgvForTerminalRunsOsascriptWithTheTerminalScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", arguments: ["-o", "cpu"], workingDirectory: "~/Projects", terminal: .terminal)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        let script = TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top' '-o' 'cpu'", workingDirectory: NSHomeDirectory() + "/Projects")
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", script])
        XCTAssertTrue(argv[2].contains("do script \"cd '\(NSHomeDirectory())/Projects' && '/usr/bin/top' '-o' 'cpu'\""), argv[2])
    }

    func testArgvForITermRunsOsascriptWithTheITermScript() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/ssh", arguments: ["it's"], terminal: .iterm2)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: #"'/usr/bin/ssh' 'it'\''s'"#, workingDirectory: nil)])
        XCTAssertTrue(argv[2].contains(#"write text "'/usr/bin/ssh' 'it'\\''s'""#), argv[2])
        XCTAssertTrue(argv[2].contains("create window with default profile\n"), argv[2])
    }

    func testArgvForGhosttyRunsTheGhosttyBinaryWithDashE() throws {
        let cli = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], workingDirectory: "/tmp", terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: ghosttyApp, inlineEnvironment: [:]),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }

    func testArgvThrowsTerminalNotFoundWhenTheTerminalAppIsMissing() {
        for choice in [TerminalChoice.terminal, TerminalChoice.iterm2, TerminalChoice.ghostty] {
            let cli = CLIConfig(executablePath: "/bin/ls", terminal: choice)
            XCTAssertThrowsError(try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: nil, inlineEnvironment: [:])) { error in
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

        let terminalArgv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: terminalApp, inlineEnvironment: environment)
        XCTAssertEqual(terminalArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: command, workingDirectory: "/tmp")])
        XCTAssertTrue(terminalArgv[2].contains("do script \"cd '/tmp' && /usr/bin/env 'A_FIRST=1' 'HOME=/Users/test/own'"), terminalArgv[2])

        cli.terminal = .iterm2
        let iTermArgv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: iTermApp, inlineEnvironment: environment)
        XCTAssertEqual(iTermArgv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.iTermScript(command: command, workingDirectory: "/tmp")])
    }

    func testInlineEnvironmentValueWithSpaceAndSingleQuoteIsQuoted() throws {
        let cli = CLIConfig(executablePath: "/bin/ls", terminal: .terminal)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: terminalApp, inlineEnvironment: ["GREETING": "it's a test"])
        XCTAssertEqual(
            argv,
            ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: #"/usr/bin/env 'GREETING=it'\''s a test' '/bin/ls'"#, workingDirectory: nil)]
        )
        XCTAssertTrue(argv[2].contains(#"do script "/usr/bin/env 'GREETING=it'\\''s a test' '/bin/ls'""#), argv[2])
    }

    func testEmptyInlineEnvironmentAddsNoEnvPrefix() throws {
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: "'/usr/bin/top'", workingDirectory: nil)])
        XCTAssertFalse(argv[2].contains("/usr/bin/env"), argv[2])
    }

    func testNoTerminalAndGhosttyIgnoreTheInlineEnvironment() throws {
        let environment = ["HOME": "/Users/test/own", "MAD_SHORTCUT_NAME": "Top"]
        let plain = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", "echo hi"], terminal: TerminalChoice.none)
        XCTAssertEqual(try TerminalCommandBuilder.preview.argv(for: plain, terminalApp: nil, inlineEnvironment: environment), ["/bin/sh", "-c", "echo hi"])
        let ghostty = CLIConfig(executablePath: "/opt/homebrew/bin/htop", arguments: ["-d", "10"], terminal: .ghostty)
        XCTAssertEqual(
            try TerminalCommandBuilder.preview.argv(for: ghostty, terminalApp: ghosttyApp, inlineEnvironment: environment),
            ["/Applications/Ghostty.app/Contents/MacOS/ghostty", "-e", "/opt/homebrew/bin/htop", "-d", "10"]
        )
    }

    // MARK: Script-file delivery (C5): the typed text holds no user data

    /// The fish payload from the audit. Quoted POSIX-style it becomes `'\'\'';open -a Calculator;#'`, and fish ends the
    /// string at the second quote and runs `open`.
    private static let fishPayload = #"\';open -a Calculator;#"#

    private func scriptPath(typedIn osascript: String) throws -> String {
        let start = try XCTUnwrap(osascript.range(of: "exec /bin/sh '"), osascript)
        let end = try XCTUnwrap(osascript[start.upperBound...].firstIndex(of: "'"), osascript)
        return String(osascript[start.upperBound..<end])
    }

    func testTerminalAndITermTypeOnlyTheScriptPathAndKeepThePayloadInsideTheScript() throws {
        let root = try makeTemporaryDirectory()
        for (choice, app) in [(TerminalChoice.terminal, terminalApp), (TerminalChoice.iterm2, iTermApp)] {
            let cli = CLIConfig(executablePath: "/bin/echo", arguments: [Self.fishPayload, "it's"], workingDirectory: "/tmp", terminal: choice)
            let argv = try TerminalCommandBuilder(scriptRoot: root).argv(for: cli, terminalApp: app, inlineEnvironment: ["K": Self.fishPayload])

            XCTAssertEqual(argv.count, 3, "\(choice)")
            let path = try scriptPath(typedIn: argv[2])
            XCTAssertTrue(path.hasPrefix(root.path + "/mad-"), path)
            XCTAssertTrue(path.hasSuffix("/run.sh"), path)
            // Typed text: our fixed prefix and our path, nothing from the config.
            let typed = TerminalCommandBuilder.typedCommand(scriptPath: path)
            XCTAssertEqual(typed, "exec /bin/sh '\(path)'")
            let expected = choice == .terminal ? TerminalCommandBuilder.terminalScript(typed: typed) : TerminalCommandBuilder.iTermScript(typed: typed)
            XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", expected], "\(choice)")
            for fragment in ["Calculator", "/bin/echo", "cd ", "/tmp", "it", "K="] {
                XCTAssertFalse(typed.contains(fragment), "\(choice) typed text leaks \(fragment)")
            }
            XCTAssertFalse(argv[2].contains("Calculator"), "\(choice)")
            // The script holds the payload inside single quotes.
            let body = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(body.contains("open -a Calculator"), body)
            let quotedPayload = TerminalCommandBuilder.shellQuoted([Self.fishPayload])
            XCTAssertEqual(
                body,
                "#!/bin/sh\nrm -f -- \"$0\"\nrmdir -- \"${0%/*}\" 2>/dev/null\ncd '/tmp' || exit 1\n"
                    + "exec /usr/bin/env \(TerminalCommandBuilder.shellQuoted(["K=" + Self.fishPayload])) '/bin/echo' \(quotedPayload) 'it'\\''s'\n"
            )
        }
    }

    func testScriptIsMode0600InAFolderOfMode0700AndFirstDeletesItself() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal)
        let argv = try TerminalCommandBuilder(scriptRoot: root).argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        let path = try scriptPath(typedIn: argv[2])
        let folder = URL(filePath: path).deletingLastPathComponent().path

        func mode(_ item: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: item)
            return try XCTUnwrap(attributes[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertTrue(URL(filePath: folder).lastPathComponent.hasPrefix("mad-"))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "#!/bin/sh")
        XCTAssertEqual(lines[1], #"rm -f -- "$0""#)
        XCTAssertEqual(lines[3], "exec '/usr/bin/top'")
    }

    func testTheScriptRunsUnderShAndRemovesItselfBeforeTheCommand() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appending(path: "out.txt")
        let cli = CLIConfig(executablePath: "/bin/sh", arguments: ["-c", #"printf '%s' "$1" > "$2""#, "sh", Self.fishPayload, output.path], terminal: .terminal)
        let argv = try TerminalCommandBuilder(scriptRoot: root).argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        let path = try scriptPath(typedIn: argv[2])

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [path]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.fishPayload, "the payload reaches the program as one argument")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the script deletes itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(filePath: path).deletingLastPathComponent().path))
    }

    func testEachLaunchGetsItsOwnScriptFolder() throws {
        let root = try makeTemporaryDirectory()
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .iterm2)
        let builder = TerminalCommandBuilder(scriptRoot: root)
        let first = try scriptPath(typedIn: builder.argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])[2])
        let second = try scriptPath(typedIn: builder.argv(for: cli, terminalApp: iTermApp, inlineEnvironment: [:])[2])
        XCTAssertNotEqual(first, second)
    }

    func testUnwritableScriptRootThrowsAndNothingIsTyped() throws {
        let missing = URL(filePath: "/nonexistent-\(UUID().uuidString)/deeper", directoryHint: .isDirectory)
        let cli = CLIConfig(executablePath: "/usr/bin/top", terminal: .terminal)
        XCTAssertThrowsError(try TerminalCommandBuilder(scriptRoot: missing).argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])) { error in
            guard case LauncherError.dataPathNotWritable = error else { return XCTFail("expected dataPathNotWritable, got \(error)") }
        }
    }

    func testPreviewBuilderWritesNoFileAndShowsTheCommand() throws {
        let cli = CLIConfig(executablePath: "/bin/echo", arguments: ["hi"], terminal: .terminal)
        let argv = try TerminalCommandBuilder.preview.argv(for: cli, terminalApp: terminalApp, inlineEnvironment: [:])
        XCTAssertEqual(argv, ["/usr/bin/osascript", "-e", TerminalCommandBuilder.terminalScript(command: "'/bin/echo' 'hi'", workingDirectory: nil)])
    }
}
