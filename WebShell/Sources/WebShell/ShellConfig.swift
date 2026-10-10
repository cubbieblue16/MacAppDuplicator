import AppKit
import DuplicatorCore
import Foundation

/// Why a web-app shortcut could not start. Copy matches the Launcher's `LauncherError` so users see one message family.
enum ShellConfigError: Error, Equatable, LocalizedError {
    case configMissing
    case configCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .configMissing:
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (MADConfig is missing.)"
        case .configCorrupt(let detail):
            "Shortcut is damaged — open macOS App Duplicator and Regenerate. (\(detail))"
        }
    }
}

/// The shortcut's `MADConfig`, validated for a web app (skeleton decisions 4 and 10).
struct ShellConfig: Sendable {
    let shortcut: ShortcutConfig
    let webApp: WebAppConfig
    let baseURL: URL
    let policy: WebHostPolicy

    /// Reads `MADConfig` from an Info.plist dictionary (normally `Bundle.main.infoDictionary`).
    static func load(infoDictionary: [String: Any]) throws -> ShellConfig {
        guard let raw = infoDictionary[ShortcutConfig.infoPlistKey] else {
            throw ShellConfigError.configMissing
        }
        guard let dictionary = raw as? [String: Any] else {
            throw ShellConfigError.configCorrupt("MADConfig is not a dictionary")
        }
        let shortcut: ShortcutConfig
        do {
            shortcut = try ShortcutConfig(plistDictionary: dictionary)
        } catch {
            throw ShellConfigError.configCorrupt(String(describing: error))
        }
        guard shortcut.kind == .webApp, let webApp = shortcut.webApp else {
            throw ShellConfigError.configCorrupt("MADConfig has no webApp settings")
        }
        let baseURL: URL
        do {
            baseURL = try WebAppURLValidator.validate(webApp.url)
        } catch {
            throw ShellConfigError.configCorrupt("webApp url is not a valid https:// address")
        }
        return ShellConfig(
            shortcut: shortcut,
            webApp: webApp,
            baseURL: baseURL,
            policy: WebHostPolicy(baseURL: baseURL, extraHosts: webApp.extraHosts)
        )
    }
}

/// Loads the bundle's configuration or shows the failure alert and exits 2.
@MainActor
func loadShellConfigOrExit(logger: LaunchLogger) -> ShellConfig {
    do {
        return try ShellConfig.load(infoDictionary: Bundle.main.infoDictionary ?? [:])
    } catch {
        failAndExit(error, logger: logger)
    }
}

/// Logs the error, shows a critical alert and exits with status 2 (skeleton decision 10). Mirrors the Launcher's `fail`.
@MainActor
func failAndExit(_ error: Error, logger: LaunchLogger) -> Never {
    logger.log("error \(error.localizedDescription)")
    logger.log("exit 2")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Shortcut could not start"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
    exit(2)
}
