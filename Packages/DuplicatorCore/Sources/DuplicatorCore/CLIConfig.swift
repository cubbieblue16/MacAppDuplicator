import Foundation

/// The terminal a command shortcut runs in (spec §6). `.none` starts the command detached, with no window.
public enum TerminalChoice: String, Codable, CaseIterable, Sendable {
    case none, terminal, iterm2, ghostty

    /// The terminal app's bundle identifier, used to locate it; nil for `.none`.
    public var bundleIdentifier: String? {
        switch self {
        case .none:
            return nil
        case .terminal:
            return "com.apple.Terminal"
        case .iterm2:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        }
    }
}

/// Command shortcut settings (spec §6). Set exactly when `ShortcutConfig.kind == .cli`. The command is an argv
/// array, never a shell string: `executablePath` is argv[0] and `arguments` follow it unchanged.
public struct CLIConfig: Codable, Hashable, Sendable {
    /// Absolute path of the executable (a leading `~` is expanded at launch).
    public var executablePath: String
    public var arguments: [String]
    /// Directory the command starts in (a leading `~` is expanded at launch); nil keeps the launcher's directory.
    public var workingDirectory: String?
    public var terminal: TerminalChoice
    /// Runs the command with `HOME` and `CFFIXED_USER_HOME` pointing at the shortcut's own HOME tree (spec §4.3).
    public var homeOverride: Bool

    public init(
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        terminal: TerminalChoice = .terminal,
        homeOverride: Bool = false
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.homeOverride = homeOverride
    }

    private enum CodingKeys: String, CodingKey {
        case executablePath, arguments, workingDirectory, terminal, homeOverride
    }

    /// Only `executablePath` is required on input; every other key falls back to the initializer default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executablePath: try container.decode(String.self, forKey: .executablePath),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            terminal: try container.decodeIfPresent(TerminalChoice.self, forKey: .terminal) ?? .terminal,
            homeOverride: try container.decodeIfPresent(Bool.self, forKey: .homeOverride) ?? false
        )
    }
}
