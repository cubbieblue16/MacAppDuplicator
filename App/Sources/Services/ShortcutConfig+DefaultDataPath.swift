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
}
