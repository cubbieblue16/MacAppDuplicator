import Foundation

/// Builds the argv the Launcher spawns for a command shortcut (spec §6). Terminal.app and iTerm2 get an AppleScript
/// run by `/usr/bin/osascript`, Ghostty gets its own binary with `-e`, and `.none` runs the command itself.
public struct TerminalCommandBuilder: Sendable {
    /// The AppleScript runner for Terminal.app and iTerm2.
    public static let osascriptPath = "/usr/bin/osascript"

    public init() {}

    /// Every element wrapped in single quotes, `'` written as `'\''`, joined with spaces: `'a' 'b c'`.
    public static func shellQuoted(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }.joined(separator: " ")
    }

    /// An AppleScript string literal: `\` escaped first, then `"`, wrapped in double quotes.
    public static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Terminal.app: activate, then `do script` the command in a new window.
    public static func terminalScript(command: String, workingDirectory: String?) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(shellCommand(command, workingDirectory: workingDirectory)))
        end tell
        """
    }

    /// iTerm2: activate, open a new window with the default profile, then `write text` the command into its session.
    /// The command goes through the session's shell (like Terminal's `do script`), so `cd … &&` works and the window
    /// stays open after the command ends. `create window with default profile command` is not used: iTerm2 treats that
    /// string as the profile command, tokenises and execs it with no shell (so `cd` and `&&` fail), interpolates `\(…)`,
    /// and closes the window when the process exits.
    public static func iTermScript(command: String, workingDirectory: String?) -> String {
        """
        tell application "iTerm2"
            activate
            create window with default profile
            tell current session of current window
                write text \(appleScriptLiteral(shellCommand(command, workingDirectory: workingDirectory)))
            end tell
        end tell
        """
    }

    /// `cd '<dir>' && <command>` when a working directory is set, else `command`.
    static func shellCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return command
        }
        return "cd \(shellQuoted([workingDirectory])) && \(command)"
    }

    /// The command as the shell in a new Terminal or iTerm2 window must run it. That window starts a fresh login shell
    /// that does not inherit `osascript`'s environment, so a non-empty `environment` is written into the command:
    /// `/usr/bin/env 'K=V' … '<exe>' '<arg>' …` with the keys sorted and every token shell-quoted. An empty one
    /// gives just the quoted command, with no `/usr/bin/env`.
    static func inlineCommand(_ command: [String], environment: [String: String]) -> String {
        guard !environment.isEmpty else {
            return shellQuoted(command)
        }
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "/usr/bin/env " + shellQuoted(assignments + command)
    }

    /// The argv for `cli`: `.none` → `[exe] + args`; `.terminal` / `.iterm2` → `["/usr/bin/osascript", "-e", script]`;
    /// `.ghostty` → `[<Ghostty.app>/Contents/MacOS/ghostty, "-e", exe] + args`. `terminalApp` is the terminal's `.app`
    /// URL. A leading `~` in `cli.workingDirectory` is expanded. `inlineEnvironment` is written into the shell command
    /// for `.terminal` / `.iterm2` only (see `inlineCommand`); `.none` and `.ghostty` ignore it, because the Launcher
    /// hands the environment to those processes through `posix_spawn`.
    /// - Throws: `LauncherError.terminalNotFound` when `cli.terminal` needs an app and `terminalApp` is nil.
    public func argv(for cli: CLIConfig, terminalApp: URL?, inlineEnvironment: [String: String]) throws -> [String] {
        let command = [cli.executablePath] + cli.arguments
        let workingDirectory = cli.workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        switch cli.terminal {
        case .none:
            return command
        case .terminal:
            guard terminalApp != nil else {
                throw LauncherError.terminalNotFound(.terminal)
            }
            let script = Self.terminalScript(command: Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", script]
        case .iterm2:
            guard terminalApp != nil else {
                throw LauncherError.terminalNotFound(.iterm2)
            }
            let script = Self.iTermScript(command: Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", script]
        case .ghostty:
            guard let terminalApp else {
                throw LauncherError.terminalNotFound(.ghostty)
            }
            let ghostty = terminalApp.appending(path: "Contents/MacOS/ghostty", directoryHint: .notDirectory)
            return [ghostty.path, "-e"] + command
        }
    }
}
