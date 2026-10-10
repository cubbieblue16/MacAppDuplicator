import AppKit
import DuplicatorCore
import Foundation

/// What the launcher would exec for a config, with secrets masked, for Diagnostics and the wizard review step (spec §7).
/// Phase 5: a file or folder shortcut previews the item it opens; a command shortcut previews the argv the Launcher plans.
struct LaunchPlanPreview: Sendable {
    var executablePath: String
    /// argv after argv[0] (planner arguments, then the shortcut's), secret values masked per `SecretMasking.maskArguments`.
    var arguments: [String]
    /// Full target environment, masked per `SecretMasking`.
    var maskedEnvironment: [String: String]
    /// Only the variables the launcher adds or changes relative to this process's environment, masked.
    var environmentAdditions: [String: String]
    var warnings: [String]
    var launchMode: LaunchMode
    /// The family AppInspector detected for the target, the one the planner used (`.native` for launcher kinds).
    var family: AppFamily

    /// Resolves a terminal choice to its installed app the way the Launcher does, through its bundle identifier.
    static let installedTerminal: @Sendable (TerminalChoice) -> URL? = { choice in
        choice.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// - Parameters:
    ///   - terminalLocator: finds the terminal app for a `.cli` preview; tests pass a closure that never touches the system.
    ///   - home: the real home folder a command's own HOME lives under; the preview never creates that folder.
    static func make(
        config: ShortcutConfig,
        bundleURL: URL?,
        terminalLocator: @escaping @Sendable (TerminalChoice) -> URL? = installedTerminal,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> LaunchPlanPreview {
        switch config.kind {
        case .file, .folder:
            return try makeItem(config: config)
        case .cli:
            return try makeCommand(config: config, bundleURL: bundleURL, terminalLocator: terminalLocator, home: home)
        case .app, .webApp:
            break
        }
        let app = try AppInspector().inspect(appAt: URL(fileURLWithPath: config.targetPath))
        let base = ProcessInfo.processInfo.environment
        let plan = DataSeparationPlanner().plan(app: app, config: config, baseEnvironment: base, shortcutBundleURL: bundleURL)
        return LaunchPlanPreview(
            executablePath: plan.executableURL.path,
            arguments: SecretMasking.maskArguments(plan.arguments),
            maskedEnvironment: SecretMasking.mask(plan.environment),
            environmentAdditions: SecretMasking.mask(plan.environmentAdditions(relativeTo: base)),
            warnings: plan.warnings,
            launchMode: plan.launchMode,
            family: app.family
        )
    }

    /// A file or folder shortcut opens its item: the preview shows the item as the "executable", with no arguments.
    private static func makeItem(config: ShortcutConfig) throws -> LaunchPlanPreview {
        guard let file = config.file else { throw LauncherError.launcherConfigMissing(config.kind) }
        return LaunchPlanPreview(
            executablePath: file.path,
            arguments: [],
            maskedEnvironment: [:],
            environmentAdditions: [:],
            warnings: FileManager.default.fileExists(atPath: file.path) ? [] : ["Item not found"],
            launchMode: .dockShortcut,
            family: .native
        )
    }

    /// A command shortcut previews the `.spawn` the Launcher plans: `/usr/bin/osascript -e <script>` for Terminal and
    /// iTerm2, Ghostty's own binary, or the executable itself for "No terminal".
    private static func makeCommand(
        config: ShortcutConfig, bundleURL: URL?, terminalLocator: @escaping @Sendable (TerminalChoice) -> URL?, home: URL
    ) throws -> LaunchPlanPreview {
        guard let cli = config.cli else { throw LauncherError.launcherConfigMissing(config.kind) }
        var planned = config
        planned.cli?.arguments = SecretMasking.maskArguments(cli.arguments)
        planned.cli?.homeOverride = false
        // Masked before planning: Terminal.app and iTerm2 write the environment into the osascript script.
        var plannedEnvironment = SecretMasking.mask(config.environment)
        if cli.homeOverride {
            // Same keys and value the planner would set; the shortcut's own environment still wins, as it does at launch.
            let ownHome = ShortcutConfig.defaultDataPath(forSlug: config.slug, home: home)
            for key in ["HOME", "CFFIXED_USER_HOME"] where plannedEnvironment[key] == nil {
                plannedEnvironment[key] = ownHome
            }
        }
        planned.environment = plannedEnvironment
        let base = ProcessInfo.processInfo.environment
        let action = try LauncherActionPlanner(realHome: home, terminalLocator: terminalLocator)
            .plan(config: planned, baseEnvironment: base, shortcutBundleURL: bundleURL)
        guard case .spawn(let executable, let arguments, let environment, _, _) = action else {
            throw LauncherError.launcherConfigMissing(config.kind)
        }
        let additions = environment.filter { base[$0.key] != $0.value }
        // The osascript script is one argument that already embeds the masked command line and environment; running
        // maskArguments over it would treat everything after its first `=` as one secret value and hide the rest.
        let isOsascript = executable.path == TerminalCommandBuilder.osascriptPath
        return LaunchPlanPreview(
            executablePath: executable.path,
            arguments: isOsascript ? arguments : SecretMasking.maskArguments(arguments),
            maskedEnvironment: SecretMasking.mask(environment),
            environmentAdditions: SecretMasking.mask(additions),
            warnings: [],
            launchMode: .dockShortcut,
            family: .native
        )
    }
}
