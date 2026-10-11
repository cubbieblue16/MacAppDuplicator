import DuplicatorCore
import Foundation

/// The editor's, the launch plan preview's and Diagnostics' decisions about the spec §4.6 helper of an application
/// shortcut: whether the menu bar icon, New Window and Erase on quit controls apply, when turning Erase on quit on needs
/// the spec §4.3 destructive confirmation, which text fields block Save, and how the helper settings read. No SwiftUI
/// and no writes; the erase checks read the file system the way the helper does at quit (`EraseOnQuitPolicy`: `lstat`
/// and `realpath`; `CanonicalPath`: `realpath`).
nonisolated enum HelperEditorPolicy {
    /// What turning Erase on quit on needs for a data folder.
    enum EraseCheck: Equatable {
        /// The folder is inside App Duplicator's data folder: the toggle turns on at once.
        case allowed
        /// A custom folder the helper would empty: the toggle turns on only after the destructive confirmation.
        case needsConfirmation(dataPath: String)
        /// The toggle stays off; the message says why.
        case refused(String)
    }

    /// Shown instead of the helper controls for web app, file, folder and command shortcuts.
    static let unavailableCaption = "The menu bar icon, New Window and Erase on quit apply to application shortcuts only."
    /// Why Erase on quit stays off while data separation is disabled or no folder is set.
    static let disabledDataMessage = "Erase on quit needs a data folder: set Data to Auto or HOME override."
    /// Title of the destructive confirmation for a custom folder.
    static let eraseConfirmationTitle = "Erase this folder on quit?"
    /// The confirmation's destructive button (`ButtonRole.destructive`).
    static let eraseConfirmButton = "Erase on Quit"
    /// Placeholder of the New Window command field.
    static let newWindowPrompt = "open -na {target}"
    /// Help text under the New Window command field.
    static let newWindowHelp = "Runs when you choose New Window in the menu bar icon's menu. {target} is the app's path, {bundleId} its bundle identifier and {dataPath} the shortcut's data folder. Split on spaces; never run by a shell."

    /// The menu bar icon, New Window and Erase on quit exist for application shortcuts only: WebShell owns the status
    /// item of web apps, and file, folder and command shortcuts leave no process behind.
    static func helperControlsVisible(kind: ShortcutKind) -> Bool {
        kind == .app
    }

    /// True when `dataPath` is an absolute path strictly inside `<home>/Library/Application Support/App Duplicator`
    /// once symbolic links are resolved: the only place where spec §4.3 lets Erase on quit turn on without the
    /// confirmation. The data root itself is not inside it.
    static func canEnableEraseWithoutConfirm(dataPath: String, home: URL) -> Bool {
        dataPath.hasPrefix("/") && CanonicalPath(dataPath).isInside(CanonicalPath(ShortcutConfig.dataRoot(home: home).path))
    }

    /// The helper's own reason for never emptying `dataPath` (`EraseOnQuitPolicy.check`), or nil when it would. A folder
    /// that does not exist yet is not refused here: the shortcut's first launch creates it and the helper checks it
    /// again at every quit.
    static func eraseRefusalReason(dataPath: String, home: URL) -> String? {
        switch EraseOnQuitPolicy.check(dataPath: dataPath, home: home) {
        case .success, .failure(.missing):
            return nil
        case .failure(let refusal):
            return refusal.logReason
        }
    }

    /// What turning Erase on quit on needs for the data folder `dataPath` under `dataMode`.
    static func eraseCheck(dataPath: String?, dataMode: DataMode, home: URL) -> EraseCheck {
        guard dataMode != .disabled, let dataPath, !dataPath.isEmpty else {
            return .refused(disabledDataMessage)
        }
        if let reason = eraseRefusalReason(dataPath: dataPath, home: home) {
            return .refused("Erase on quit never empties this folder: \(reason).")
        }
        return canEnableEraseWithoutConfirm(dataPath: dataPath, home: home) ? .allowed : .needsConfirmation(dataPath: dataPath)
    }

    /// `eraseCheck(dataPath:dataMode:home:)` for the folder `config` uses: its `dataPath`, else its default folder.
    static func eraseCheck(for config: ShortcutConfig, home: URL) -> EraseCheck {
        eraseCheck(dataPath: config.effectiveDataPath(home: home), dataMode: config.dataMode, home: home)
    }

    /// Message of the destructive confirmation for a custom folder.
    static func eraseConfirmationMessage(name: String, dataPath: String) -> String {
        "Every time \(name) quits, everything inside \(dataPath) is deleted permanently. It is not moved to the Trash. This folder is outside App Duplicator's data folder."
    }

    /// Why the New Window command cannot be saved, or nil.
    static func newWindowValidation(_ template: String?) -> String? {
        NewWindowCommandBuilder.validationMessage(for: template)
    }

    /// Why the language code cannot be saved, or nil (a blank field means no override).
    static func languageValidation(_ code: String?) -> String? {
        LanguageCode.validationMessage(for: code)
    }

    /// The first helper-related reason Save stays disabled for an application shortcut draft, or nil. Other kinds hide
    /// these fields, so they never block Save.
    static func validationMessage(for draft: ShortcutConfig) -> String? {
        guard draft.kind == .app else { return nil }
        return languageValidation(draft.languageCode) ?? newWindowValidation(draft.newWindowCommand)
    }

    /// The draft as saved: the language code and the New Window command trimmed (blank becomes nil), and Erase on quit
    /// turned off while data separation is disabled, where it could never run. Other kinds are returned unchanged.
    static func saveConfig(draft: ShortcutConfig) -> ShortcutConfig {
        guard draft.kind == .app else { return draft }
        var config = draft
        config.languageCode = trimmedOrNil(draft.languageCode)
        config.newWindowCommand = trimmedOrNil(draft.newWindowCommand)
        if config.dataMode == .disabled {
            config.eraseOnQuit = false
        }
        return config
    }

    /// Why the New Window item will not appear in the menu, or nil when it will or when neither setting is used.
    static func newWindowNote(for config: ShortcutConfig, home: URL) -> String? {
        guard config.kind == .app else { return nil }
        let hasTemplate = trimmedOrNil(config.newWindowCommand) != nil
        switch (config.menuBarIcon, hasTemplate) {
        case (true, false):
            return "New Window is hidden until you enter a command."
        case (false, true):
            return "New Window appears only while Menu bar icon is on."
        case (false, false):
            return nil
        case (true, true):
            let resolved = config.resolvingDefaultDataPath(home: home)
            guard HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) == nil else { return nil }
            return "New Window stays hidden: the command uses {dataPath} and the shortcut has no data folder."
        }
    }

    /// The launch plan preview's helper line, `Menu bar icon · New Window · Erase on quit` or the part that applies;
    /// nil when the shortcut starts no helper.
    static func helperLine(for config: ShortcutConfig, home: URL) -> String? {
        let resolved = config.resolvingDefaultDataPath(home: home)
        guard HelperPlan.isNeeded(for: resolved) else { return nil }
        var items: [String] = []
        if HelperPlan.showsMenuBarIcon(for: resolved) {
            items.append("Menu bar icon")
            if HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) != nil {
                items.append(HelperMenuText.newWindow)
            }
        }
        if HelperPlan.eraseDataPath(for: resolved) != nil {
            items.append("Erase on quit")
        }
        return items.joined(separator: " · ")
    }

    /// Diagnostics value of the New Window command: the argv the helper runs, masked, or why there is none.
    static func newWindowText(for config: ShortcutConfig, home: URL) -> String {
        guard config.kind == .app, trimmedOrNil(config.newWindowCommand) != nil else { return "None" }
        let resolved = config.resolvingDefaultDataPath(home: home)
        guard let argv = HelperPlan.newWindowArguments(for: resolved, targetPath: resolved.targetPath) else {
            return "Hidden (the command uses {dataPath} and the shortcut has no data folder)"
        }
        let command = SecretMasking.maskArguments(argv).joined(separator: " ")
        return config.menuBarIcon ? command : command + " (hidden: the menu bar icon is off)"
    }

    /// Diagnostics value of Erase on quit: off, on with its folder, or on but refused by the helper's guard.
    static func eraseText(for config: ShortcutConfig, home: URL) -> String {
        guard config.eraseOnQuit else { return "Off" }
        guard let dataPath = HelperPlan.eraseDataPath(for: config.resolvingDefaultDataPath(home: home)) else {
            return "Off (no data folder to erase)"
        }
        if let reason = eraseRefusalReason(dataPath: dataPath, home: home) {
            return "On, but the folder is never erased: \(reason)"
        }
        return "On: \(dataPath)"
    }

    /// Diagnostics value of the spec §4.5 language override.
    static func languageText(_ code: String?) -> String {
        guard let trimmed = trimmedOrNil(code) else { return "System" }
        return LanguageCode.isValid(trimmed) ? trimmed : "\(trimmed) (not a valid language code)"
    }

    /// Diagnostics rows of an application shortcut, in this order: Menu bar icon, Erase on quit, New Window command,
    /// Language. Empty for every other kind.
    static func diagnosticsRows(for config: ShortcutConfig, home: URL) -> [ProfileSummary.Row] {
        guard config.kind == .app else { return [] }
        return [
            ProfileSummary.Row(label: "Menu bar icon", value: config.menuBarIcon ? "On" : "Off"),
            ProfileSummary.Row(label: "Erase on quit", value: eraseText(for: config, home: home)),
            ProfileSummary.Row(label: "New Window command", value: newWindowText(for: config, home: home)),
            ProfileSummary.Row(label: "Language", value: languageText(config.languageCode)),
        ]
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
