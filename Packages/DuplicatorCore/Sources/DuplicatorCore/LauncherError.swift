import Foundation

/// Every failure the launcher reports (spec §4.7). Exit codes live in `LauncherError+ExitCode.swift`.
public enum LauncherError: Error, LocalizedError {
    case configMissing
    case configCorrupt(String)
    case targetNotFound(path: String, bundleID: String)
    case dataPathNotWritable(String)
    case execFailed(errno: Int32, path: String)
    case notAnAppBundle(String)
    /// A file or folder shortcut's item, its opener app, a command's executable or working directory is missing.
    case fileNotFound(path: String)
    /// The command shortcut's terminal app is not installed.
    case terminalNotFound(TerminalChoice)
    /// `posix_spawn` failed for a command shortcut.
    case spawnFailed(errno: Int32, path: String)
    /// A launcher-kind `MADConfig` has no `file` / `cli` settings.
    case launcherConfigMissing(ShortcutKind)

    public var errorDescription: String? {
        switch self {
        case .configMissing:
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        case .configCorrupt(let detail):
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (\(detail))"
        case .targetNotFound(let path, let bundleID):
            return "The target app was not found.\nStored path: \(path)\nBundle ID: \(bundleID)"
        case .dataPathNotWritable(let path):
            return "The data folder is not writable: \(path)"
        case .execFailed(let code, let path):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        case .notAnAppBundle(let path):
            return "\(path) is not a valid application bundle."
        case .fileNotFound(let path):
            return "The file, folder or command was not found.\nStored path: \(path)"
        case .terminalNotFound(let terminal):
            return "\(Self.terminalName(terminal)) is not installed. Choose another terminal in macOS App Duplicator."
        case .spawnFailed(let code, let path):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        case .launcherConfigMissing(let kind):
            return "Shortcut is damaged — open macOS App Duplicator and Regenerate. (The \(kind.rawValue) settings are missing.)"
        }
    }

    private static func terminalName(_ terminal: TerminalChoice) -> String {
        switch terminal {
        case .none:
            return "The selected terminal"
        case .terminal:
            return "Terminal"
        case .iterm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        }
    }
}
