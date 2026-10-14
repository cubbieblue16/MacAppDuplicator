import AppKit
import DuplicatorCore
import WebKit

/// Owns the main web view, its configuration and every popup window (skeleton decisions 5, 6, 8, 10).
@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    /// Called with the page title whenever `webView.title` changes. Feeds the badge parser;
    /// the window title has its own observation in `MainWindowController`.
    var titleDidChange: ((String) -> Void)?
    /// Called when a main-frame provisional load fails with a user-visible error.
    var provisionalLoadDidFail: ((Error) -> Void)?
    /// Called when a main-frame navigation commits.
    var navigationDidCommit: (() -> Void)?

    /// Brings the app and its main window forward; set by `WebShellFeatures.install`. Dialogs call it when their
    /// window is hidden.
    var bringToFront: (@MainActor () -> Void)?

    private let shell: ShellConfig
    private let logger: LaunchLogger
    private let userContentController: WKUserContentController
    private var popupWindows: [NSWindow] = []
    /// Popups `hidePopupWindows()` hid, so `revealHiddenPopups()` can show them again.
    private var hiddenPopups = HiddenWindowRegistry<NSWindow>()
    private var titleObservation: NSKeyValueObservation?
    /// Termination times of the main web view's content process inside `crashWindow`.
    private var crashDates: [Date] = []
    private static let crashWindow: TimeInterval = 60
    private static let crashLimit = 3
    /// Termination times per popup web view, keyed by identity; removed when the popup's window closes.
    private var popupCrashDates: [ObjectIdentifier: [Date]] = [:]

    init(shell: ShellConfig, logger: LaunchLogger) {
        self.shell = shell
        self.logger = logger
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: WebShellScripts.badgeBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: WebShellScripts.notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Off explicitly: a page cannot open windows without a user gesture (popup spam, window.open from timers).
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: shell.webApp.dataStoreID)
        userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.customUserAgent = shell.webApp.userAgent.customUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.titleDidChange?(self.webView.title ?? "")
            }
        }
    }

    /// Registers a page-to-native message handler. `WKUserContentController` retains `handler` strongly,
    /// so the handler must not retain this coordinator or its web view.
    func addMessageHandler(_ handler: WKScriptMessageHandler, name: String) {
        userContentController.add(handler, name: name)
    }

    func loadHome() {
        load(shell.baseURL)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    // MARK: - Navigation policy (skeleton decision 6)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let decision = NavigationPolicy.decide(
            url: url,
            scheme: url.scheme,
            targetFrameIsMain: navigationAction.targetFrame?.isMainFrame,
            navigationType: navigationAction.navigationType,
            policy: shell.policy
        )
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openExternally:
            openExternally(url)
            closeIfEmptyPopup(webView)
            return .cancel
        case .blocked(let reason):
            logger.log(reason)
            return .cancel
        }
    }

    /// A popup whose first navigation went to the default browser has nothing to show; close it.
    private func closeIfEmptyPopup(_ popup: WKWebView) {
        guard popup !== webView, popup.url == nil || popup.url?.absoluteString == "about:blank" else { return }
        popup.window?.close()
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            logger.log("redirect host=\(url.host() ?? "")")
        } else {
            logger.log("redirect scheme=\(scheme)")
        }
        if scheme != "http", scheme != "https" {
            guard confirmExternalOpen(url) else {
                logger.log("external open declined scheme=\(scheme)")
                return
            }
        }
        if !NSWorkspace.shared.open(url) {
            logger.log("error no application opens scheme=\(scheme)")
        }
    }

    /// Asks before a non-web URL goes to the workspace; Cancel is the default button. `mailto:` is exempt.
    private func confirmExternalOpen(_ url: URL) -> Bool {
        let handlerName = NSWorkspace.shared.urlForApplication(toOpen: url).map { appURL in
            let info = Bundle(url: appURL)?.infoDictionary
            return (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: appURL.path)
        }
        guard let prompt = ExternalOpenPrompt.make(for: url, handlerName: handlerName) else { return true }
        bringToFront?()
        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        alert.alertStyle = .warning
        // The first button is the default (Return) button.
        alert.addButton(withTitle: prompt.cancelButtonTitle)
        alert.addButton(withTitle: prompt.openButtonTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Load results

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        webView.window?.subtitle = WindowSubtitle.text(for: webView.url)
        guard webView === self.webView else { return }
        navigationDidCommit?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !Self.isPolicyCancellation(nsError) else { return }
        logLoadError(nsError)
        guard webView === self.webView else { return }
        provisionalLoadDidFail?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !Self.isPolicyCancellation(nsError) else { return }
        logLoadError(nsError)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.log("error web content process terminated")
        let now = Date()
        guard webView === self.webView else {
            let key = ObjectIdentifier(webView)
            var dates = popupCrashDates[key, default: []]
            dates.removeAll { now.timeIntervalSince($0) > Self.crashWindow }
            dates.append(now)
            if dates.count >= Self.crashLimit {
                logger.log("error popup web content process crashed \(dates.count) times within \(Int(Self.crashWindow))s; closing popup")
                popupCrashDates[key] = nil
                if let window = popupWindows.first(where: { $0.contentView === webView }) {
                    window.close()
                } else {
                    webView.window?.close()
                }
            } else {
                popupCrashDates[key] = dates
                webView.reload()
            }
            return
        }
        crashDates.removeAll { now.timeIntervalSince($0) > Self.crashWindow }
        crashDates.append(now)
        if crashDates.count >= Self.crashLimit {
            logger.log("error web content process crashed \(crashDates.count) times within \(Int(Self.crashWindow))s; not reloading")
            provisionalLoadDidFail?(NSError(
                domain: "WebShell",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The page's web content process keeps crashing.",
                    NSURLErrorFailingURLErrorKey: webView.url ?? shell.baseURL,
                ]
            ))
            return
        }
        if webView.url == nil {
            loadHome()
        } else {
            webView.reload()
        }
    }

    /// Forgets recorded content-process crashes; called when the user presses Retry on the error view.
    func resetCrashCount() {
        crashDates.removeAll()
    }

    /// Cancellations caused by this shell (external redirects) or by a newer load are not load failures.
    private static func isPolicyCancellation(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }

    private func logLoadError(_ error: NSError) {
        let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        logger.log("error load host=\(failingURL?.host() ?? "") domain=\(error.domain) code=\(error.code)")
    }

    // MARK: - Popups (skeleton decision 6)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `javaScriptCanOpenWindowsAutomatically` is off, so WebKit only asks for a script window after a user
        // gesture; clicked links carry one by definition.
        switch NavigationPolicy.popupDecision(
            url: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame,
            sourceURL: navigationAction.sourceFrame.request.url,
            userInitiated: true,
            policy: shell.policy
        ) {
        case .ignore:
            return nil
        case .openExternally:
            if let url = navigationAction.request.url {
                openExternally(url)
            }
            return nil
        case .openInApp:
            break
        }
        let width = max(320, windowFeatures.width.map { CGFloat($0.doubleValue) } ?? 900)
        let height = max(240, windowFeatures.height.map { CGFloat($0.doubleValue) } ?? 700)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        // WebKit requires the passed configuration: it shares the data store, process pool and user scripts.
        let popup = WKWebView(frame: frame, configuration: configuration)
        popup.customUserAgent = self.webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = shell.shortcut.name
        window.subtitle = WindowSubtitle.text(for: navigationAction.request.url)
        window.contentView = popup
        window.delegate = self
        window.center()
        popupWindows.append(window)
        logger.log("popup host=\(navigationAction.request.url?.host() ?? "")")
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    /// Hides every open popup window (background mode hides the main window the same way).
    func hidePopupWindows() {
        for window in popupWindows {
            window.orderOut(nil)
        }
        hiddenPopups.remember(popupWindows)
    }

    /// Orders front the popups that background mode hid; the counterpart of `hidePopupWindows()`.
    func revealHiddenPopups() {
        for window in hiddenPopups.takeAll() {
            window.orderFront(nil)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popupWindows.first(where: { $0.contentView === webView }) else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let popup = window.contentView {
            popupCrashDates[ObjectIdentifier(popup)] = nil
        }
        popupWindows.removeAll { $0 === window }
        hiddenPopups.forget(window)
    }
}
