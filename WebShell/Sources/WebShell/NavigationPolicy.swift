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

/// What the shell does when a page asks for a new window.
enum PopupDecision: Equatable {
    /// Open the in-app popup window.
    case openInApp
    /// Hand the URL to the default browser; no popup.
    case openExternally
    /// Refuse the new window.
    case ignore
}

enum NavigationPolicy {
    /// Decision for a new-window request (`createWebViewWith`). A user's click on a link to a site the app does not
    /// keep in its window goes to the default browser; script-initiated `window.open` stays in-app so OAuth sign-in
    /// popups complete. A script that opens a blank window first (`window.open('')`, `about:blank`, a `blob:` preview)
    /// and navigates it later also stays in-app; the popup's own `decide()` polices that later navigation.
    /// `file:` and custom schemes are refused.
    static func popupDecision(url: URL?, navigationType: WKNavigationType, policy: WebHostPolicy) -> PopupDecision {
        let scheme = url?.scheme?.lowercased() ?? ""
        switch scheme {
        case "", "about", "blob":
            // A blank-first popup is only meaningful for script; a clicked link to about:blank has nothing to show.
            return navigationType == .linkActivated ? .ignore : .openInApp
        case "http", "https":
            if let url, navigationType == .linkActivated, !policy.allowsInPlace(url) {
                return .openExternally
            }
            return .openInApp
        default:
            return .ignore
        }
    }

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
