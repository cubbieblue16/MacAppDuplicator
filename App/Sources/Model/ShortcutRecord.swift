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
    /// Whether this install wrote the bundle (security C3). Deliberately has no default: every construction decides.
    var provenance: Provenance

    /// Where a bundle came from. A bundle carrying `MADConfig` is only data: anyone can write one, so the app must not
    /// regenerate and re-sign a bundle it did not write until the user has reviewed what it runs.
    enum Provenance: Hashable, Sendable {
        /// Written by this install: its Info.plist carries this install's token, or (legacy and madctl bundles, which
        /// carry no token) it is signed the way the configured signing identity signs.
        case own
        /// Received, downloaded or planted; `reason` is shown to the user (for example "signed by Developer ID ...").
        case foreign(reason: String)
    }

    var name: String { config.name }
    var needsRebuild: Bool { engineVersion < ShortcutConfig.currentEngineVersion }
    /// True when the bundle was not written by this install; Rebuild All skips it and Save asks for approval first.
    var isForeign: Bool {
        if case .foreign = provenance { return true }
        return false
    }
    /// The user-facing reason a foreign bundle is not trusted; nil for the install's own bundles.
    var foreignReason: String? {
        if case .foreign(let reason) = provenance { return reason }
        return nil
    }

    /// The host of a web app's address (`chat.example.test`), shown under its name in the sidebar; nil for a native shortcut.
    var webAppHost: String? {
        guard config.kind == .webApp, let address = config.webApp?.url else { return nil }
        return URL(string: address)?.host(percentEncoded: false)
    }
}
