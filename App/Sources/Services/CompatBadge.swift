import DuplicatorCore

/// Sidebar/editor compatibility badge (spec §7). `verified` and `unsupported` come from profiles in Phase 3;
/// Phase 2 only produces `auto`, `homeOnly` and `unknown`.
enum CompatBadge: String, Sendable {
    case verified = "Verified"
    case auto = "Auto"
    case homeOnly = "HOME only"
    case unsupported = "Unsupported"
    case unknown = "Unknown"

    var label: String { rawValue }

    static func badge(for app: InspectedApp?) -> CompatBadge {
        guard let app else { return .unknown }
        return app.family == .native ? .homeOnly : .auto
    }
}
