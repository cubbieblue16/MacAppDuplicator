import DuplicatorCore
import Foundation

extension ShortcutConfig {
    /// A copy with a nil `dataPath` filled in with the default folder for `slug`, unless data separation is disabled.
    func resolvingDefaultDataPath(home: URL) -> ShortcutConfig {
        guard dataMode != .disabled, dataPath == nil else { return self }
        var copy = self
        copy.dataPath = ShortcutConfig.defaultDataPath(forSlug: slug, home: home)
        return copy
    }

    /// The data folder this shortcut uses: its `dataPath`, else the default folder for its slug. Nil when data
    /// separation is disabled and no folder was ever set (the shortcut shares the original app's data).
    func effectiveDataPath(home: URL) -> String? {
        resolvingDefaultDataPath(home: home).dataPath
    }

    /// `~/Library/Application Support/App Duplicator`, the parent of every default data folder.
    static func dataRoot(home: URL) -> URL {
        URL(fileURLWithPath: defaultDataPath(forSlug: "slug", home: home), isDirectory: true).deletingLastPathComponent()
    }
}
