import Foundation

/// The one-time review of shortcuts an earlier App Duplicator (or madctl) built before install tokens existed
/// (`ShortcutRecord.isLegacyCandidate`). Under ad hoc signing each of them reads as not created here (security C3), so
/// instead of one Trust and Rebuild per shortcut, `LegacyTrustReviewSheet` shows all of them at once, every value
/// unmasked. Nothing is written until the user chooses Trust All and Rebuild (`AppState.trustLegacyShortcuts`).
struct LegacyTrustReview: Identifiable {
    let id = UUID()
    /// One per shortcut, in library order: the bundle's own on-disk config and its current signature.
    let approvals: [ForeignShortcutApproval]

    /// Rebuild All's skip reason for a legacy candidate: it points at the review instead of at each shortcut's editor.
    static let rebuildAllSkipReason = "built by an earlier version; use Review Earlier Shortcuts\u{2026}"
}
