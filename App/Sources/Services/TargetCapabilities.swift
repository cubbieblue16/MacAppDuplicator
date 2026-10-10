import DuplicatorCore

/// What a target allows, shared by the wizard and the editor. Each rule mirrors the decision `DataSeparationPlanner`
/// makes at launch, so the UI never offers an option the launcher would override.
extension InspectedApp {
    /// Dock Shortcut cannot exec an Apple platform binary or a launch-constrained app from a foreign bundle (spec §4.1);
    /// the planner forces System Launch for them.
    var requiresSystemLaunch: Bool {
        isPlatformBinary || hasLaunchConstraints
    }

    /// Why Dock Shortcut is unavailable for this target, or nil when it is available.
    var dockShortcutUnavailableReason: String? {
        guard requiresSystemLaunch else { return nil }
        let reason = isPlatformBinary ? "an Apple platform binary" : "launch-constrained"
        return "Dock Shortcut is unavailable: \(name) is \(reason), so it always starts through System Launch and shows its own Dock tile."
    }
}

extension AppFamily {
    /// The families for which the planner adds `--force-dark-mode` (spec §4.5). Other families get no dark override.
    var supportsForcedDarkMode: Bool {
        switch self {
        case .chromium, .electron, .todesktop: true
        case .firefox, .eclipse, .native: false
        }
    }
}
