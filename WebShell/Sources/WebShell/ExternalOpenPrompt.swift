import Foundation

/// The confirmation shown before the shell hands a non-web URL (`vnc:`, `smb:`, `ssh:`, `zoommtg:` ...) to the
/// workspace. A page link click can otherwise launch any registered handler with an attacker-chosen payload.
/// Pure so the decision and the wording are testable without AppKit.
struct ExternalOpenPrompt: Equatable {
    /// Schemes opened without a prompt: a mail link only starts a compose window.
    static let exemptSchemes: Set<String> = ["mailto"]
    /// Longest URL text shown in the alert.
    static let maxDisplayedURLLength = 200

    let messageText: String
    let informativeText: String
    let openButtonTitle = "Open"
    let cancelButtonTitle = "Cancel"

    /// The prompt for `url`, or nil when the URL needs none (http(s) never reaches this path; `mailto:` is exempt).
    /// - Parameter handlerName: Display name of the app that would open the URL; nil when none is registered.
    static func make(for url: URL, handlerName: String?) -> ExternalOpenPrompt? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              scheme != "http", scheme != "https",
              !exemptSchemes.contains(scheme) else { return nil }
        let handler = handlerName.flatMap { $0.isEmpty ? nil : $0 } ?? "an external app"
        return ExternalOpenPrompt(
            messageText: "Open \(scheme) link in \(handler)?",
            informativeText: displayedURL(url)
        )
    }

    /// The URL text, cut to `maxDisplayedURLLength` characters with an ellipsis.
    static func displayedURL(_ url: URL) -> String {
        let text = url.absoluteString
        guard text.count > maxDisplayedURLLength else { return text }
        return String(text.prefix(maxDisplayedURLLength)) + "..."
    }
}
