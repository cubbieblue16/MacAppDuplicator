import Foundation

/// Builds the argv the Launcher spawns for a command shortcut (spec §6). Terminal.app and iTerm2 get an AppleScript
/// run by `/usr/bin/osascript`, Ghostty gets its own binary with `-e`, and `.none` runs the command itself.
///
/// Terminal.app and iTerm2 deliver text as keystrokes to the user's login shell, which may be fish, where `\'` inside
/// single quotes is an escape and the POSIX quoting below breaks out (C5). So by default the command is written to a
/// private POSIX `sh` script and only `/bin/sh '<script path>'`, which holds no user data, is typed. The typed line
/// does not `exec`, so the user's login shell stays open after the command exits, as it did before.
public struct TerminalCommandBuilder: Sendable {
    /// The AppleScript runner for Terminal.app and iTerm2.
    public static let osascriptPath = "/usr/bin/osascript"

    /// How the command reaches a Terminal.app or iTerm2 shell.
    public enum Delivery: Sendable, Equatable {
        /// Write `mad-<uuid>/run.sh` (0600, in a 0700 directory) under `root` and type only its path.
        case scriptFile(root: URL)
        /// Type the quoted command itself. Only for the Launch Plan preview, which shows the command and is never run.
        case typedPreview
    }

    let delivery: Delivery

    /// - Parameter scriptRoot: where `mad-<uuid>` script directories are created; tests pass their own folder.
    public init(scriptRoot: URL = FileManager.default.temporaryDirectory) {
        self.delivery = .scriptFile(root: scriptRoot)
    }

    private init(delivery: Delivery) {
        self.delivery = delivery
    }

    /// A builder whose Terminal and iTerm2 output embeds the readable command and writes no file (preview only).
    public static var preview: TerminalCommandBuilder { TerminalCommandBuilder(delivery: .typedPreview) }

    /// The script file's contents: POSIX sh that deletes itself (and its then-empty folder) first, so a secret in the
    /// command or environment does not linger on disk, then changes directory and `exec`s the quoted argv.
    static func scriptBody(command: String, workingDirectory: String?) -> String {
        var lines = ["#!/bin/sh", #"rm -f -- "$0""#, #"rmdir -- "${0%/*}" 2>/dev/null"#]
        if let workingDirectory, !workingDirectory.isEmpty {
            lines.append("cd \(shellQuoted([workingDirectory])) || exit 1")
        }
        lines.append("exec \(command)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The only text typed into the terminal: no user data, just our own path.
    static func typedCommand(scriptPath: String) -> String {
        "/bin/sh " + shellQuoted([scriptPath])
    }

    /// Writes `body` to `<root>/mad-<uuid>/run.sh`, the file 0600 in a 0700 folder, and returns the file's path.
    /// - Throws: `LauncherError.dataPathNotWritable` when the folder or file cannot be created.
    static func writeScript(_ body: String, under root: URL, fileManager: FileManager = .default) throws -> String {
        let directory = root.appending(path: "mad-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "run.sh", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // `createDirectory` applies the umask; set the mode outright so a stricter or looser umask cannot change it.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            guard fileManager.createFile(atPath: file.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw LauncherError.dataPathNotWritable(file.path)
            }
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.dataPathNotWritable(directory.path)
        }
        return file.path
    }

    /// The shell command for a Terminal or iTerm2 window: `/bin/sh '<script>'` after writing the script, or the
    /// readable quoted command for the preview.
    private func windowCommand(_ command: String, workingDirectory: String?) throws -> String {
        switch delivery {
        case .scriptFile(let root):
            let path = try Self.writeScript(Self.scriptBody(command: command, workingDirectory: workingDirectory), under: root)
            return Self.typedCommand(scriptPath: path)
        case .typedPreview:
            return Self.shellCommand(command, workingDirectory: workingDirectory)
        }
    }

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
        terminalScript(typed: shellCommand(command, workingDirectory: workingDirectory))
    }

    /// Terminal.app with `typed` as the exact text to run.
    static func terminalScript(typed: String) -> String {
        """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(typed))
        end tell
        """
    }

    /// iTerm2: activate, open a new window with the default profile, then `write text` the command into its session.
    /// The command goes through the session's shell (like Terminal's `do script`), so `cd … &&` works and the window
    /// stays open after the command ends. `create window with default profile command` is not used: iTerm2 treats that
    /// string as the profile command, tokenises and execs it with no shell (so `cd` and `&&` fail), interpolates `\(…)`,
    /// and closes the window when the process exits.
    public static func iTermScript(command: String, workingDirectory: String?) -> String {
        iTermScript(typed: shellCommand(command, workingDirectory: workingDirectory))
    }

    /// iTerm2 with `typed` as the exact text to write.
    static func iTermScript(typed: String) -> String {
        """
        tell application "iTerm2"
            activate
            create window with default profile
            tell current session of current window
                write text \(appleScriptLiteral(typed))
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
            let typed = try windowCommand(Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", Self.terminalScript(typed: typed)]
        case .iterm2:
            guard terminalApp != nil else {
                throw LauncherError.terminalNotFound(.iterm2)
            }
            let typed = try windowCommand(Self.inlineCommand(command, environment: inlineEnvironment), workingDirectory: workingDirectory)
            return [Self.osascriptPath, "-e", Self.iTermScript(typed: typed)]
        case .ghostty:
            guard let terminalApp else {
                throw LauncherError.terminalNotFound(.ghostty)
            }
            let ghostty = terminalApp.appending(path: "Contents/MacOS/ghostty", directoryHint: .notDirectory)
            return [ghostty.path, "-e"] + command
        }
    }
}
