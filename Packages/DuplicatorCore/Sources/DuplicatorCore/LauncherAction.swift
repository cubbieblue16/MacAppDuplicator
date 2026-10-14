import Foundation

/// What the Launcher does for a file, folder or command shortcut (spec §6). Both actions end with the Launcher exiting.
public enum LauncherAction: Equatable, Sendable {
    /// Open `items` with `openerApp`, or with each item's default handler when nil (file and folder shortcuts).
    case open(items: [URL], openerApp: URL?)
    /// Start `executable` with exactly these arguments (argv[1...]) and environment (command shortcuts).
    /// `workingDirectory` is nil for Terminal.app and iTerm2, whose script `cd`s itself. `displayArguments` is the
    /// user's command, `[executable path] + arguments`, with secret values masked by `SecretMasking.maskArguments`, the
    /// same for every terminal choice. It is what the Launcher logs; the raw argv is never logged, because for
    /// Terminal.app and iTerm2 it is an AppleScript that holds the whole command and its inline environment.
    case spawn(
        executable: URL,
        arguments: [String],
        displayArguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        terminal: TerminalChoice
    )
}

/// Turns a launcher-kind `ShortcutConfig` into a `LauncherAction`: validates paths, finds the terminal, builds the
/// environment and, for `CLIConfig.homeOverride`, materialises the shortcut's HOME tree (spec §4.3).
/// Not `Sendable`: it stores a `FileManager`, which is not `Sendable` (same as `LaunchPreparer` and `HomeTreeBuilder`).
public struct LauncherActionPlanner {
    let fileManager: FileManager
    let realHome: URL
    let terminalLocator: @Sendable (TerminalChoice) -> URL?
    let terminalCommands: TerminalCommandBuilder

    /// - Parameter terminalLocator: the terminal app's `.app` URL, or nil when it is not installed. Called only for
    ///   choices that have a `bundleIdentifier`.
    /// - Parameter terminalCommands: how Terminal.app and iTerm2 commands are delivered; the default writes the run
    ///   script under the system temporary directory, and the Launch Plan preview passes `.preview` to write nothing.
    public init(
        fileManager: FileManager = .default,
        realHome: URL,
        terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?,
        terminalCommands: TerminalCommandBuilder = TerminalCommandBuilder()
    ) {
        self.fileManager = fileManager
        self.realHome = realHome
        self.terminalLocator = terminalLocator
        self.terminalCommands = terminalCommands
    }

    /// - Throws: `LauncherError` (`launcherConfigMissing`, `fileNotFound`, `terminalNotFound`, `dataPathNotWritable`,
    ///   and `configCorrupt` for `.app` / `.webApp`, which are not launcher kinds).
    public func plan(config: ShortcutConfig, baseEnvironment: [String: String], shortcutBundleURL: URL?) throws -> LauncherAction {
        switch config.kind {
        case .file, .folder:
            guard let file = config.file else {
                throw LauncherError.launcherConfigMissing(config.kind)
            }
            return try planOpen(file)
        case .cli:
            guard let cli = config.cli else {
                throw LauncherError.launcherConfigMissing(.cli)
            }
            return try planSpawn(cli, config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)
        case .app, .webApp:
            throw LauncherError.configCorrupt("\(config.kind.rawValue) is not a launcher kind")
        }
    }

    private func planOpen(_ file: FileConfig) throws -> LauncherAction {
        let path = FileConfig.normalizedPath(file.path)
        guard !path.isEmpty, fileManager.fileExists(atPath: path) else {
            throw LauncherError.fileNotFound(path: path)
        }
        var openerApp: URL?
        if let rawOpener = file.openerAppPath, !rawOpener.isEmpty {
            let opener = FileConfig.normalizedPath(rawOpener)
            guard fileManager.fileExists(atPath: opener) else {
                throw LauncherError.fileNotFound(path: opener)
            }
            openerApp = URL(filePath: opener, directoryHint: .isDirectory)
        }
        return .open(items: [URL(filePath: path, directoryHint: .checkFileSystem)], openerApp: openerApp)
    }

    private func planSpawn(
        _ cli: CLIConfig,
        config: ShortcutConfig,
        baseEnvironment: [String: String],
        shortcutBundleURL: URL?
    ) throws -> LauncherAction {
        // A config built in memory (or decoded before this check existed) gets the same refusal as a decoded one.
        if let problem = cli.controlCharacterProblem ?? CLIConfig.environmentControlCharacterProblem(config.environment) {
            throw LauncherError.configCorrupt(problem)
        }
        var resolved = cli
        resolved.executablePath = (cli.executablePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.executablePath, isDirectory: &isDirectory), !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolved.executablePath) else {
            throw LauncherError.fileNotFound(path: resolved.executablePath)
        }

        var workingDirectory: URL?
        if let rawDirectory = cli.workingDirectory, !rawDirectory.isEmpty {
            let path = (rawDirectory as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                throw LauncherError.fileNotFound(path: path)
            }
            workingDirectory = URL(filePath: path, directoryHint: .isDirectory)
            resolved.workingDirectory = path
        } else {
            resolved.workingDirectory = nil
        }

        let terminalApp = cli.terminal.bundleIdentifier == nil ? nil : terminalLocator(cli.terminal)
        // Checked before the HOME tree is created, so a missing terminal leaves nothing behind.
        if cli.terminal.bundleIdentifier != nil, terminalApp == nil {
            throw LauncherError.terminalNotFound(cli.terminal)
        }

        // What the shortcut adds to the environment; `config.environment` wins over everything else.
        var additions: [String: String] = [DataSeparationPlanner.shortcutNameKey: config.name]
        if let shortcutBundleURL {
            additions[DataSeparationPlanner.shortcutBundleKey] = shortcutBundleURL.path
        }
        if cli.homeOverride {
            let home = try materializeHome(for: config)
            additions["HOME"] = home.path
            additions["CFFIXED_USER_HOME"] = home.path
        }
        additions.merge(config.environment) { _, shortcut in shortcut }

        // `.none` and Ghostty receive `additions` through the spawned process's environment below; Terminal.app and
        // iTerm2 start a fresh login shell, so the builder also writes them into the shell command.
        let argv = try terminalCommands.argv(for: resolved, terminalApp: terminalApp, inlineEnvironment: additions)
        guard let executable = argv.first else {
            throw LauncherError.launcherConfigMissing(.cli)
        }

        var environment = baseEnvironment.filter { !$0.key.hasPrefix(DataSeparationPlanner.internalVariablePrefix) }
        environment.merge(additions) { _, added in added }

        let scriptsChangeDirectory = cli.terminal == .terminal || cli.terminal == .iterm2
        return .spawn(
            executable: URL(filePath: executable, directoryHint: .notDirectory),
            arguments: Array(argv.dropFirst()),
            displayArguments: [resolved.executablePath] + SecretMasking.maskArguments(cli.arguments),
            environment: environment,
            workingDirectory: scriptsChangeDirectory ? nil : workingDirectory,
            terminal: cli.terminal
        )
    }

    /// Creates `ShortcutConfig.defaultDataPath(forSlug:home:)` and builds the HOME tree in it. Returns the effective
    /// HOME, which is `<path>/<NSUserName()>` when the folder already held other files (spec §4.3). A slug that
    /// `ShortcutConfig.isValidSlug` refuses throws `LauncherError.configCorrupt` before anything is created.
    private func materializeHome(for config: ShortcutConfig) throws -> URL {
        // A decoded config was checked already; this also covers a config built in memory.
        guard ShortcutConfig.isValidSlug(config.slug) else {
            throw LauncherError.configCorrupt("invalid slug")
        }
        let path = URL(filePath: ShortcutConfig.defaultDataPath(forSlug: config.slug, home: realHome), directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            let symlinkEntries = config.homeSymlinkEntries ?? HomeTreeBuilder.defaultSymlinkEntries
            return try HomeTreeBuilder(fileManager: fileManager, realHome: realHome, symlinkEntries: symlinkEntries).materialize(at: path)
        } catch {
            throw LauncherError.dataPathNotWritable(path.path)
        }
    }
}
