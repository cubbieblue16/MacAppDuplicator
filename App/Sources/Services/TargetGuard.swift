import DuplicatorCore
import Foundation

/// Refuses App Duplicator shortcuts as targets (final review M5). A shortcut-to-shortcut target chains launchers, and
/// a shortcut that targets itself makes its launcher exec its own binary again. The wizard, the editor's Target section
/// and the sidebar drop path check this before accepting a target; `ShortcutBuilder` checks it again before every write.
enum TargetGuard {
    /// True when the bundle's Info.plist carries `MADConfig` (`ShortcutConfig.infoPlistKey`, the key `LibraryScanner`
    /// reads to recognise a shortcut). Any value counts, even one that no longer decodes: that bundle is still a
    /// launcher. A missing or unreadable Info.plist is not a shortcut.
    static func isShortcutBundle(at url: URL) -> Bool {
        InstalledApps.infoDictionary(ofAppAt: url)?[ShortcutConfig.infoPlistKey] != nil
    }

    /// The sentence shown when a shortcut is offered as a target; the name is the bundle's file name without `.app`.
    static func refusalMessage(forAppAt url: URL) -> String {
        "\(url.deletingPathExtension().lastPathComponent) is an App Duplicator shortcut, not an app. Choose the original app instead."
    }
}
