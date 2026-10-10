import DuplicatorCore
import Foundation

extension TargetResolver {
    /// The target's current location as `resolve(config:)` finds it (the stored path while it still holds the app,
    /// else the first LaunchServices hit for the bundle id), or nil when the bundle id is empty or nothing is found.
    /// The data-path guard and export check this location as well as the stored path (re-review Minor 4).
    func resolvedPath(targetPath: String, targetBundleIdentifier: String) -> String? {
        guard !targetBundleIdentifier.isEmpty else { return nil }
        let probe = ShortcutConfig(name: "", slug: "", bundleIdentifier: "", targetPath: targetPath, targetBundleIdentifier: targetBundleIdentifier)
        do {
            return try resolve(config: probe).path
        } catch {
            // `resolve` throws only `targetNotFound`; the stored path is checked on its own, so there is nothing to add.
            return nil
        }
    }

    func resolvedPath(for config: ShortcutConfig) -> String? {
        resolvedPath(targetPath: config.targetPath, targetBundleIdentifier: config.targetBundleIdentifier)
    }
}
