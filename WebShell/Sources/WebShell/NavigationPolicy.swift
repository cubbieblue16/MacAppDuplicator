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
    /// Decision for a new-window request (`createWebViewWith`).
    ///
    /// A popup opens in-app only when the frame that asked for it is the main frame AND that frame is on a host the
    /// web app keeps in its window. An ad iframe, an embedded widget or a foreign page cannot spawn a window that
    /// carries the app's name and data store. Otherwise a click (or user-initiated open) on an http(s) target goes to
    /// the default browser, and everything else is refused. A clicked link to a site the app does not keep in its
    /// window also goes to the default browser even from a trusted source.
    ///
    /// A script that opens a blank window first (`window.open('')`, `about:blank`, a `blob:` preview) and
    /// navigates it later stays in-app when its source qualifies; the popup's own `decide()` polices that later
    /// navigation. `file:` and custom schemes are refused.
    /// - Parameters:
    ///   - url: The popup's initial URL, nil for `window.open('')`.
    ///   - navigationType: How the action started.
    ///   - sourceIsMainFrame: Whether the frame that requested the window is its page's main frame.
    ///   - sourceURL: That frame's current URL; its host must pass `policy`.
    ///   - userInitiated: Whether a user gesture started the action.
    static func popupDecision(
        url: URL?,
        navigationType: WKNavigationType,
        sourceIsMainFrame: Bool,
        sourceURL: URL?,
        userInitiated: Bool,
        policy: WebHostPolicy
    ) -> PopupDecision {
        let sourceIsTrusted = sourceIsMainFrame && (sourceURL.map { policy.allowsInPlace($0) } ?? false)
        let scheme = url?.scheme?.lowercased() ?? ""
        switch scheme {
        case "", "about", "blob":
            // A blank-first popup is only meaningful for script; a clicked link to about:blank has nothing to show.
            return navigationType != .linkActivated && sourceIsTrusted ? .openInApp : .ignore
        case "http", "https":
            if let url, navigationType == .linkActivated, !policy.allowsInPlace(url) {
                return userInitiated ? .openExternally : .ignore
            }
            if sourceIsTrusted {
                return .openInApp
            }
            let isClickOrOther = navigationType == .linkActivated || navigationType == .other
            return isClickOrOther && userInitiated ? .openExternally : .ignore
        default:
            return .ignore
        }
    }

    /// Pure navigation decision.
    /// - Parameters:
    ///   - targetFrameIsMain: `nil` when the action has no target frame (a new-window request),
    ///     otherwise whether the target frame is the main frame.
    static func decide(
        url: URL,
        scheme: String?,
        targetFrameIsMain: Bool?,
        navigationType: WKNavigationType,
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
        if targetFrameIsMain == nil {
            // Popup creation path: `popupDecision` judges the request in `createWebViewWith`. Popup windows
            // themselves are not exempt: their main-frame navigations take the host policy below.
            return .allow
        }
        return policy.allowsInPlace(url) ? .allow : .openExternally
    }
}
