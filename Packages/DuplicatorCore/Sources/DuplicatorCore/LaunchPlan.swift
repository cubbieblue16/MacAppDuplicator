import Foundation

/// Everything the launcher needs to start the target (spec §3.1, §4.4).
public struct LaunchPlan: Equatable, Sendable {
    /// Target executable; becomes argv[0].
    public var executableURL: URL
    /// argv after argv[0]: planner arguments, then `ShortcutConfig.arguments` (spec §4.4).
    public var arguments: [String]
    /// Complete environment for the target (spec §4.4).
    public var environment: [String: String]
    public var directoriesToCreate: [URL]
    /// Set when HOME override applies; `HomeTreeBuilder` materialises it at launch.
    public var homeOverridePath: URL?
    public var warnings: [String]
    /// Effective launch mode; may differ from the config when the planner forces System Launch (spec §4.1).
    public var launchMode: LaunchMode

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        directoriesToCreate: [URL],
        homeOverridePath: URL?,
        warnings: [String],
        launchMode: LaunchMode
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.directoriesToCreate = directoriesToCreate
        self.homeOverridePath = homeOverridePath
        self.warnings = warnings
        self.launchMode = launchMode
    }

    /// Replaces the planned home with the effective home returned by `HomeTreeBuilder.materialize(at:)`
    /// (which may be `<path>/<NSUserName()>`, spec §4.3). `HOME` and `CFFIXED_USER_HOME` are rewritten only
    /// where they still hold the planned path, so a user-supplied value in `ShortcutConfig.environment` wins.
    public func applyingEffectiveHome(_ effectiveHome: URL) -> LaunchPlan {
        guard let planned = homeOverridePath else { return self }
        var plan = self
        for key in ["HOME", "CFFIXED_USER_HOME"] where plan.environment[key] == planned.path {
            plan.environment[key] = effectiveHome.path
        }
        plan.homeOverridePath = effectiveHome
        return plan
    }

    /// Variables whose value differs from, or is missing in, `base`. System Launch passes these to
    /// `NSWorkspace.OpenConfiguration.environment`, which LaunchServices merges over the caller's environment.
    public func environmentAdditions(relativeTo base: [String: String]) -> [String: String] {
        environment.filter { base[$0.key] != $0.value }
    }
}
