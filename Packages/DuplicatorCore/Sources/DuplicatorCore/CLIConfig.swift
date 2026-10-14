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
    /// - Throws: `DecodingError.dataCorrupted` when `controlCharacterProblem` finds one, so a foreign config that hides
    ///   a control character in the command is refused when it is scanned (C5), not when it is launched.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executablePath: try container.decode(String.self, forKey: .executablePath),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            terminal: try container.decodeIfPresent(TerminalChoice.self, forKey: .terminal) ?? .terminal,
            homeOverride: try container.decodeIfPresent(Bool.self, forKey: .homeOverride) ?? false
        )
        if let problem = controlCharacterProblem {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: problem)
            )
        }
    }

    /// True when `text` holds a Unicode scalar below 0x20 (this includes tab, newline and ETX) or DEL (0x7F). Terminal
    /// and iTerm2 receive a command as keystrokes, where such a scalar ends or rewrites the line, and no field of a
    /// command shortcut has a legitimate use for one.
    public static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A user-facing sentence naming the first command field (executable, argument, working directory) that holds a
    /// control character, or nil when all are clean. The environment belongs to `ShortcutConfig`; see
    /// `environmentControlCharacterProblem(_:)`.
    public var controlCharacterProblem: String? {
        if Self.containsControlCharacter(executablePath) {
            return "The program path may not contain control characters."
        }
        if arguments.contains(where: Self.containsControlCharacter) {
            return "Arguments may not contain control characters."
        }
        if let workingDirectory, Self.containsControlCharacter(workingDirectory) {
            return "The working directory may not contain control characters."
        }
        return nil
    }

    /// The same check for a command shortcut's environment, keys and values.
    public static func environmentControlCharacterProblem(_ environment: [String: String]) -> String? {
        let dirty = environment.contains { containsControlCharacter($0.key) || containsControlCharacter($0.value) }
        return dirty ? "Environment variables may not contain control characters." : nil
    }
}
