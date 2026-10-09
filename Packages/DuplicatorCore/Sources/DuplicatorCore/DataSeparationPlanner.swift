import Foundation

/// Pure function from (target, shortcut config, inherited environment) to a `LaunchPlan`
/// (spec §3.1, §4.1, §4.3, §4.4, §4.5). Runs at creation time (preview) and again at every launch.
public struct DataSeparationPlanner {
    /// Environment variables added for every launch (spec §4.4).
    public static let shortcutNameKey = "MAD_SHORTCUT_NAME"
    public static let shortcutBundleKey = "MAD_SHORTCUT_BUNDLE"
    /// Launcher-internal variables carry this prefix and are stripped from the inherited environment (spec §4.4).
    public static let internalVariablePrefix = "MAD_"

    public init() {}

    /// Builds the launch plan.
    ///
    /// Order (spec §4.4): argv = `[target] + plannerArgs + config.arguments`;
    /// env = inherited (minus `MAD_*`) + plannerEnv + `MAD_SHORTCUT_*` + `config.environment`, later wins.
    ///
    /// Phase 3 (Compatibility profiles) inserts a `profile` parameter here, matching spec §3.1
    /// `(InspectedApp, Profile?, ShortcutConfig) -> LaunchPlan`: profile args go between the planner args and
    /// `config.arguments`, profile env between the planner env and `config.environment`, and a profile's
    /// data-mode override replaces the family default in `.auto`.
    ///
    /// - Parameter shortcutBundleURL: the shortcut bundle, exported as `MAD_SHORTCUT_BUNDLE`; nil in previews.
    public func plan(
        app: InspectedApp,
        config: ShortcutConfig,
        baseEnvironment: [String: String],
        shortcutBundleURL: URL? = nil
    ) -> LaunchPlan {
        var plannerArguments: [String] = []
        var plannerEnvironment: [String: String] = [:]
        var directories: [URL] = []
        var homeOverridePath: URL?
        var warnings: [String] = []
        var launchMode = config.launchMode

        // Spec §4.1: platform binaries and launch-constrained apps are killed when exec'd from a foreign bundle.
        if app.isPlatformBinary || app.hasLaunchConstraints {
            launchMode = .systemLaunch
            let reason = app.isPlatformBinary ? "an Apple platform binary" : "launch-constrained"
            warnings.append("\(app.name) is \(reason); Dock Shortcut mode is unavailable, so it starts through System Launch and owns its Dock tile.")
        }

        func applyHomeOverride(_ path: URL) {
            homeOverridePath = path
            directories.append(path)
            plannerEnvironment["HOME"] = path.path
            plannerEnvironment["CFFIXED_USER_HOME"] = path.path
        }

        // Spec §4.3: data separation.
        let dataURL = config.dataPath.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        switch config.dataMode {
        case .disabled:
            break
        case .homeOverride:
            if let dataURL {
                applyHomeOverride(dataURL)
            } else {
                warnings.append("HOME override needs a data path; data separation skipped.")
            }
        case .auto:
            guard let dataURL else {
                warnings.append("Auto data separation needs a data path; data separation skipped.")
                break
            }
            switch app.family {
            case .chromium, .electron, .todesktop:
                plannerArguments.append("--user-data-dir=\(dataURL.path)")
                directories.append(dataURL)
            case .firefox:
                plannerArguments += ["--profile", dataURL.path, "--no-remote"]
                directories.append(dataURL)
            case .eclipse:
                let workspace = dataURL.appending(path: "workspace", directoryHint: .isDirectory)
                let configuration = dataURL.appending(path: "configuration", directoryHint: .isDirectory)
                plannerArguments += ["-data", workspace.path, "-configuration", configuration.path]
                directories += [dataURL, workspace, configuration]
            case .native:
                if app.isSandboxed {
                    warnings.append("sandboxed app; its container cannot be moved. Multiple instances may share data.")
                } else {
                    warnings.append("untested app; HOME override applied")
                    applyHomeOverride(dataURL)
                }
            }
        }

        // Spec §4.5: appearance. `-AppleInterfaceStyle` is never emitted.
        switch config.appearance {
        case .system:
            break
        case .light:
            plannerArguments += ["-NSRequiresAquaSystemAppearance", "YES"]
        case .dark:
            switch app.family {
            case .chromium, .electron, .todesktop:
                plannerArguments.append("--force-dark-mode")
            case .firefox, .eclipse, .native:
                warnings.append("Dark override is not available for \(app.family.rawValue) apps")
            }
        }

        // Spec §4.5: language.
        if let code = config.languageCode, !code.isEmpty {
            plannerArguments += ["-AppleLanguages", "(\(code))", "-AppleLocale", code]
        }

        // Spec §4.4: environment, later wins.
        var environment = baseEnvironment.filter { !$0.key.hasPrefix(Self.internalVariablePrefix) }
        environment.merge(plannerEnvironment) { _, planner in planner }
        environment[Self.shortcutNameKey] = config.name
        if let shortcutBundleURL {
            environment[Self.shortcutBundleKey] = shortcutBundleURL.path
        }
        environment.merge(config.environment) { _, shortcut in shortcut }

        return LaunchPlan(
            executableURL: app.executableURL,
            arguments: plannerArguments + config.arguments,
            environment: environment,
            directoriesToCreate: directories,
            homeOverridePath: homeOverridePath,
            warnings: warnings,
            launchMode: launchMode
        )
    }
}
