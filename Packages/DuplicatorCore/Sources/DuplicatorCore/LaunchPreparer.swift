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

/// Launcher steps before exec (spec §3.4 steps 2–4), kept in Core so they are unit-tested:
/// read `MADConfig`, resolve the target, validate and inspect it (spec §9), plan, create directories,
/// materialise the HOME tree.
public struct LaunchPreparer {
    let fileManager: FileManager
    let realHome: URL

    public init(fileManager: FileManager = .default, realHome: URL) {
        self.fileManager = fileManager
        self.realHome = realHome
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
}
