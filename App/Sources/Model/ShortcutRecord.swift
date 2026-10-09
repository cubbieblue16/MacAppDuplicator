import DuplicatorCore
import Foundation

/// One shortcut bundle found in a library folder (spec §7 sidebar row + editor source of truth).
struct ShortcutRecord: Identifiable, Hashable, Sendable {
    var id: URL { bundleURL }
    var bundleURL: URL
    var config: ShortcutConfig
    /// `MADEngineVersion` from the bundle's Info.plist.
    var engineVersion: Int
    /// `Contents/Resources/AppIcon.icns` when present.
    var iconURL: URL?
    /// `CFBundleShortVersionString` of the target, when the target exists and declares one.
    var targetVersion: String?
    var targetExists: Bool
    var modifiedDate: Date

    var name: String { config.name }
    var needsRebuild: Bool { engineVersion < ShortcutConfig.currentEngineVersion }
}
