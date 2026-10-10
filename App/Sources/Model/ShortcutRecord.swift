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

    /// The host of a web app's address (`chat.example.test`), shown under its name in the sidebar; nil for a native shortcut.
    var webAppHost: String? {
        guard config.kind == .webApp, let address = config.webApp?.url else { return nil }
        return URL(string: address)?.host(percentEncoded: false)
    }
}
