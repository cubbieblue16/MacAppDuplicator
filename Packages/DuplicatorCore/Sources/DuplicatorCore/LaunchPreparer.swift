import Foundation

/// The resolved inputs for one launch.
public struct PreparedLaunch: Equatable, Sendable {
    public let config: ShortcutConfig
    public let app: InspectedApp
    public let plan: LaunchPlan

    public init(config: ShortcutConfig, app: InspectedApp, plan: LaunchPlan) {
        self.config = config
        self.app = app
        self.plan = plan
    }
}

/// What the Launcher runs for one shortcut: an app shortcut's prepared exec, or a file, folder or command action.
public enum PreparedShortcut: Sendable {
    case app(PreparedLaunch)
    case launcher(LauncherAction, ShortcutConfig)
}

/// Launcher steps before exec (spec §3.4 steps 2–4), kept in Core so they are unit-tested:
/// read `MADConfig`, resolve the target, validate and inspect it (spec §9), plan, create directories,
/// materialise the HOME tree.
public struct LaunchPreparer {
    let fileManager: FileManager
    let realHome: URL
    let progress: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - fileManager: the file manager used for directory creation and the HOME tree.
    ///   - realHome: the user's real home directory.
    ///   - progress: receives one short status line before each filesystem step that can block on a folder-access prompt (the Launcher writes it to the shortcut log).
    public init(fileManager: FileManager = .default, realHome: URL, progress: (@Sendable (String) -> Void)? = nil) {
        self.fileManager = fileManager
        self.realHome = realHome
        self.progress = progress
    }

    /// - Parameters:
    ///   - infoDictionary: the shortcut's Info.plist (`Bundle.main.infoDictionary` in the launcher).
    ///   - shortcutBundleURL: the shortcut bundle (`Bundle.main.bundleURL`).
    ///   - baseEnvironment: the launcher's own environment.
    /// - Throws: `LauncherError` (`configMissing`, `configCorrupt`, `targetNotFound`, `notAnAppBundle`, `dataPathNotWritable`).
    public func prepare(infoDictionary: [String: Any], shortcutBundleURL: URL, baseEnvironment: [String: String]) throws -> PreparedLaunch {
        guard let rawConfig = infoDictionary[ShortcutConfig.infoPlistKey] else {
            throw LauncherError.configMissing
        }
        guard let configDictionary = rawConfig as? [String: Any] else {
            throw LauncherError.configCorrupt("MADConfig is not a dictionary")
        }
        let config = try ShortcutConfig(plistDictionary: configDictionary)
        let targetURL = try TargetResolver().resolve(config: config)
        let app = try AppInspector().inspect(appAt: targetURL)
        var plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)

        for directory in plan.directoriesToCreate {
            progress?("create \(directory.path)")
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw LauncherError.dataPathNotWritable(directory.path)
            }
            guard fileManager.isWritableFile(atPath: directory.path) else {
                throw LauncherError.dataPathNotWritable(directory.path)
            }
        }
        if let home = plan.homeOverridePath {
            progress?("data folder \(home.path)")
            do {
                let symlinkEntries = config.homeSymlinkEntries ?? HomeTreeBuilder.defaultSymlinkEntries
                let effectiveHome = try HomeTreeBuilder(fileManager: fileManager, realHome: realHome, symlinkEntries: symlinkEntries)
                    .materialize(at: home)
                plan = plan.applyingEffectiveHome(effectiveHome)
            } catch {
                throw LauncherError.dataPathNotWritable(home.path)
            }
        }
        return PreparedLaunch(config: config, app: app, plan: plan)
    }

    /// Reads `MADConfig` and dispatches by kind: `.app` → `prepare(infoDictionary:shortcutBundleURL:baseEnvironment:)`
    /// unchanged; `.file` / `.folder` / `.cli` → `LauncherActionPlanner`; `.webApp` → `configCorrupt` (web app bundles
    /// run WebShell, never the Launcher).
    /// - Parameters:
    ///   - realHome: the user's real home, for a command's HOME-override tree. The Launcher passes the same URL it
    ///     gave `init(realHome:)`.
    ///   - terminalLocator: the terminal app's `.app` URL, or nil when it is not installed.
    /// - Throws: `LauncherError`.
    public func prepareShortcut(
        infoDictionary: [String: Any],
        shortcutBundleURL: URL,
        baseEnvironment: [String: String],
        realHome: URL,
        terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?
    ) throws -> PreparedShortcut {
        guard let rawConfig = infoDictionary[ShortcutConfig.infoPlistKey] else {
            throw LauncherError.configMissing
        }
        guard let configDictionary = rawConfig as? [String: Any] else {
            throw LauncherError.configCorrupt("MADConfig is not a dictionary")
        }
        let config = try ShortcutConfig(plistDictionary: configDictionary)
        switch config.kind {
        case .app:
            return .app(try prepare(infoDictionary: infoDictionary, shortcutBundleURL: shortcutBundleURL, baseEnvironment: baseEnvironment))
        case .webApp:
            throw LauncherError.configCorrupt("web app bundles are run by WebShell")
        case .file, .folder, .cli:
            let planner = LauncherActionPlanner(fileManager: fileManager, realHome: realHome, terminalLocator: terminalLocator)
            let action = try planner.plan(config: config, baseEnvironment: baseEnvironment, shortcutBundleURL: shortcutBundleURL)
            return .launcher(action, config)
        }
    }
}
