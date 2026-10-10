import DuplicatorCore
import Foundation

/// Gives every shortcut in the library its own slug (final review M6). `ShortcutConfig.slug(for:)` folds
/// "Claude Work", "Claude-Work" and "claude  work" to the same `claude-work`; two shortcuts on one slug would share a
/// bundle id and a default data folder, which silently defeats separation. Core's `slug(for:)` stays unchanged: only
/// the app knows the library.
enum SlugAllocator {
    /// `proposed` when no slug in `taken` matches it, else `proposed-2`, `proposed-3`, … (the first free one).
    /// Matching ignores case: Launch Services compares bundle ids case-insensitively and the default data folder sits
    /// on a case-insensitive volume, so `Claude-Work` already occupies `claude-work`.
    static func uniqueSlug(proposed: String, taken: Set<String>) -> String {
        let occupied = Set(taken.map { $0.lowercased() })
        guard occupied.contains(proposed.lowercased()) else { return proposed }
        var suffix = 2
        while occupied.contains("\(proposed)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(proposed)-\(suffix)"
    }

    /// The slugs `records` already use. `excluding` names the bundle being edited, so a rename may keep its own slug.
    static func takenSlugs(in records: [ShortcutRecord], excluding bundleURL: URL? = nil) -> Set<String> {
        let excluded = bundleURL?.standardizedFileURL
        return Set(records.filter { $0.bundleURL.standardizedFileURL != excluded }.map(\.config.slug))
    }
}
