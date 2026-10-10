import DuplicatorCore
import Foundation
import WebKit

/// What the shell does with one navigation action (skeleton decision 6).
enum NavigationDecision: Equatable {
    /// Let WebKit load it.
    case allow
    /// Cancel silently.
    case cancel
    /// Hand the URL to the workspace and cancel the in-web-view load.
    case openExternally
    /// Cancel and log; `reason` is host/scheme-safe text only.
    case blocked(reason: String)
}

enum NavigationPolicy {
    /// Pure navigation decision.
    /// - Parameters:
    ///   - targetFrameIsMain: `nil` when the action has no target frame (a new-window request),
    ///     otherwise whether the target frame is the main frame.
    ///   - isPrimaryWebView: `true` for the app's main web view, `false` for popup web views
    ///     (popups are exempt from the in-place host policy so OAuth completes).
    static func decide(
        url: URL,
        scheme: String?,
        targetFrameIsMain: Bool?,
        navigationType: WKNavigationType,
        isPrimaryWebView: Bool = true,
        policy: WebHostPolicy
    ) -> NavigationDecision {
        // Only subframes are exempt. New-window (nil frame) and main-frame actions get the scheme checks,
        // so a `mailto:` link with target=_blank never opens an empty popup.
        if let targetFrameIsMain, !targetFrameIsMain {
            return .allow
        }
        let scheme = scheme?.lowercased() ?? ""
        if scheme == "about" || WebHostPolicy.isInternalScheme(url) {
            return .allow
        }
        guard scheme == "http" || scheme == "https" else {
            // Never forward file: to the workspace, and only open other schemes for a real link click.
            if scheme != "file", navigationType == .linkActivated {
                return .openExternally
            }
            return .blocked(reason: "blocked scheme=\(scheme)")
        }
        if targetFrameIsMain == nil || !isPrimaryWebView {
            // Popup creation path and popup windows are exempt from the in-place policy.
            return .allow
        }
        return policy.allowsInPlace(url) ? .allow : .openExternally
    }
}
