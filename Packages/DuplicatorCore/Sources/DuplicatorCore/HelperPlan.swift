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

    /// True when the helper shows its status item: an application shortcut with the menu bar icon on. Data separation
    /// does not matter here; only erase-on-quit needs a separated folder.
    public static func showsMenuBarIcon(for config: ShortcutConfig) -> Bool {
        config.kind == .app && config.menuBarIcon
    }

    /// The New Window argv of an application shortcut: `newWindowCommand` rendered by `NewWindowCommandBuilder`, with
    /// `targetPath` (the app the launch resolved, which may differ from the stored `targetPath`) for `{target}` and the
    /// stored data folder for `{dataPath}` while data separation is on. Nil for other kinds, for a nil or blank template,
    /// and for a template that names `{dataPath}` when separation is disabled or no folder is stored; the menu item is
    /// then hidden.
    public static func newWindowArguments(for config: ShortcutConfig, targetPath: String) -> [String]? {
        guard config.kind == .app else { return nil }
        var dataPath: String?
        if config.dataMode != .disabled, let stored = config.dataPath, !stored.isEmpty {
            dataPath = stored
        }
        return NewWindowCommandBuilder.argv(
            template: config.newWindowCommand,
            targetPath: targetPath,
            targetBundleIdentifier: config.targetBundleIdentifier,
            dataPath: dataPath
        )
    }
}
