import Foundation

/// Whether an application shortcut needs the spec §4.6 helper, and which folder erase-on-quit may empty. Only `.app`
/// shortcuts have one: WebShell owns the status item of web apps, and file, folder and command shortcuts exit at once.
public enum HelperPlan {
    /// True for an application shortcut with the menu bar icon on or an erasable data folder.
    public static func isNeeded(for config: ShortcutConfig) -> Bool {
        config.kind == .app && (config.menuBarIcon || eraseDataPath(for: config) != nil)
    }

    /// The stored data folder when erase-on-quit applies: an application shortcut with `eraseOnQuit` on, data separation
    /// not disabled and a non-empty `dataPath`. Never touches the file system; `EraseOnQuitPolicy` checks the path again
    /// at run time.
    public static func eraseDataPath(for config: ShortcutConfig) -> String? {
        guard config.kind == .app, config.eraseOnQuit, config.dataMode != .disabled,
              let dataPath = config.dataPath, !dataPath.isEmpty else { return nil }
        return dataPath
    }
}
