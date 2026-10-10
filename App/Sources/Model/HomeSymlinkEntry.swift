import DuplicatorCore
import Foundation

/// The rule for entries in the Settings → Data symlink list (spec §4.3; final review I3, M11): one file or folder name
/// directly inside the real home, the same rule `HomeTreeBuilder` applies when it builds a HOME tree.
enum HomeSymlinkEntry {
    /// The form an entry is stored in: surrounding spaces removed.
    static func normalized(_ entry: String) -> String {
        entry.trimmingCharacters(in: .whitespaces)
    }

    /// Nil when `entry` can join `existing`; otherwise the message the editor shows. Duplicates are matched
    /// case-insensitively, like the default APFS volume.
    static func problem(with entry: String, existing: [String]) -> String? {
        let name = normalized(entry)
        guard !name.isEmpty else { return "Enter a file or folder name, such as .aws." }
        guard HomeTreeBuilder.isPlainEntryName(name) else {
            return "“\(name)” is not a single name. Use a file or folder directly inside your home folder, such as .aws."
        }
        let folded = name.folding(options: .caseInsensitive, locale: nil)
        if existing.contains(where: { normalized($0).folding(options: .caseInsensitive, locale: nil) == folded }) {
            return "“\(name)” is already in the list."
        }
        return nil
    }
}
