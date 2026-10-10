import CompatProfiles
import DuplicatorCore

/// Compatibility badge (spec §7): `Verified` (profile tested), `Auto` (family detected, untested), `HOME only`,
/// `Unsupported` (the profile marks the app single-instance) and `Unknown`.
enum CompatBadge: String, Sendable {
    case verified = "Verified"
    case auto = "Auto"
    case homeOnly = "HOME only"
    case unsupported = "Unsupported"
    case unknown = "Unknown"

    var label: String { rawValue }

    /// Evaluated in this order: no inspected app → `unknown`; a profile marked `unsupported` → `unsupported`; a
    /// `verified` profile → `verified`; a sandboxed native app → `unknown` (its container ignores a HOME override,
    /// final review M9); another native app → `homeOnly`; every other family → `auto`. A `partial` profile changes nothing.
    static func badge(for app: InspectedApp?, profile: AppProfile? = nil) -> CompatBadge {
        guard let app else { return .unknown }
        switch profile?.status {
        case .unsupported: return .unsupported
        case .verified: return .verified
        case .partial, nil: break
        }
        if app.family == .native {
            return app.isSandboxed ? .unknown : .homeOnly
        }
        return .auto
    }
}
