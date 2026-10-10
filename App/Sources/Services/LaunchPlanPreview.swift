import DuplicatorCore
import Foundation

/// What the launcher would exec for a config, with secrets masked, for Diagnostics and the wizard review step (spec §7).
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
    /// The family AppInspector detected for the target, the one the planner used.
    var family: AppFamily

    static func make(config: ShortcutConfig, bundleURL: URL?) throws -> LaunchPlanPreview {
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
}
