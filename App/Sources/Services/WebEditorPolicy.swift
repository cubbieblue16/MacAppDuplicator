import DuplicatorCore
import Foundation

/// The editor rules for a web app, kept out of the views so they are unit-tested (Phase 4 skeleton decision 16).
enum WebEditorPolicy {
    /// The address to store (`absoluteString` of the validated URL), or the validator's refusal.
    static func validatedURL(_ text: String) -> Result<String, WebAppURLError> {
        do {
            return .success(try WebAppURLValidator.validate(text).absoluteString)
        } catch let error as WebAppURLError {
            return .failure(error)
        } catch {
            return .failure(.invalidAddress)
        }
    }

    /// One host per line; blank lines dropped; trimmed, lower-cased and de-duplicated by `WebAppConfig.normalizedHosts`.
    static func parsedHosts(from text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return WebAppConfig.normalizedHosts(lines)
    }

    /// A blank field means "use the default pattern", stored as nil.
    static func badgePattern(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Non-nil when the typed pattern would not be used: the shell falls back to the default (`BadgeTitleParser`).
    static func badgeWarning(for text: String) -> String? {
        guard let pattern = badgePattern(from: text), BadgeTitleParser(pattern: pattern).usedFallbackPattern else { return nil }
        return "That pattern is not valid or has no capture group, so the default \(BadgeTitleParser.defaultPattern) is used."
    }

    /// `Fetched from site` is the `.copied` mode, which only a wizard-built icon has: the editor cannot fetch a site icon,
    /// so it is offered only while it is already the saved mode (Task 6 Deviation 4).
    static func iconModes(saved: IconMode) -> [IconMode] {
        saved == .copied ? [.copied, .custom, .generated] : [.custom, .generated]
    }

    static func iconLabel(_ mode: IconMode) -> String {
        switch mode {
        case .copied: "Fetched from site"
        case .custom: "Custom file"
        case .generated: "Generated tile"
        }
    }

    static func zoomLabel(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    static func removeWebDataMessage(shortcutName: String) -> String {
        "This signs “\(shortcutName)” out of every site and deletes its cookies, cache and local storage from this Mac. The shortcut stays, and this cannot be undone."
    }

    /// The config Save writes for a web app. It trims the name, keeps the saved slug and bundle identifier (a rename
    /// must not move the shell to a new bundle id, because WebKit files its store under that id), pins the store
    /// identifier and the remembered zoom (neither is editable), normalizes the extra hosts, and drops background mode
    /// when the menu bar icon is off. The editor passes no icon data with it, so `iconMode == .copied` keeps the
    /// bundle's existing `AppIcon.icns` (Task 4's `regenerate`).
    static func saveConfig(draft: ShortcutConfig, saved: ShortcutConfig) -> ShortcutConfig {
        var config = draft
        config.name = draft.name.trimmingCharacters(in: .whitespaces)
        config.slug = saved.slug
        config.bundleIdentifier = saved.bundleIdentifier
        if var web = draft.webApp {
            if let savedWeb = saved.webApp {
                web.dataStoreID = savedWeb.dataStoreID
                web.pageZoom = savedWeb.pageZoom
            }
            web.extraHosts = WebAppConfig.normalizedHosts(web.extraHosts)
            if !config.menuBarIcon { web.backgroundMode = false }
            config.webApp = web
        }
        return config
    }
}
