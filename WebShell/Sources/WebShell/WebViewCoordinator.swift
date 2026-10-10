import AppKit
import DuplicatorCore
import WebKit

/// Owns the main web view, its configuration and every popup window (skeleton decisions 5, 6, 8, 10).
@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    /// Called with the page title whenever `webView.title` changes. Reserved for Task 3 (badge parsing);
    /// the window title has its own observation in `MainWindowController`.
    var titleDidChange: ((String) -> Void)?
    /// Called when a main-frame provisional load fails with a user-visible error.
    var provisionalLoadDidFail: ((Error) -> Void)?
    /// Called when a main-frame navigation commits.
    var navigationDidCommit: (() -> Void)?

    private let shell: ShellConfig
    private let logger: LaunchLogger
    private let userContentController: WKUserContentController
    private var popupWindows: [NSWindow] = []
    private var titleObservation: NSKeyValueObservation?

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
        if WebHostPolicy.isInternalScheme(url) {
            return .allow
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            openExternally(url)
            return .cancel
        }
        guard let targetFrame = navigationAction.targetFrame else {
            // A new-window request (target=_blank, window.open): allow so WebKit asks for a popup.
            return .allow
        }
        if !targetFrame.isMainFrame || webView !== self.webView {
            // Subframes are never redirected; popup windows are exempt so OAuth completes.
            return .allow
        }
        if shell.policy.allowsInPlace(url) {
            return .allow
        }
        openExternally(url)
        return .cancel
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            logger.log("redirect host=\(url.host() ?? "")")
        } else {
            logger.log("redirect scheme=\(scheme)")
        }
        if !NSWorkspace.shared.open(url) {
            logger.log("error no application opens scheme=\(scheme)")
        }
    }

    // MARK: - Load results

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
        webView.reload()
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
        window.contentView = popup
        window.delegate = self
        window.center()
        popupWindows.append(window)
        logger.log("popup host=\(navigationAction.request.url?.host() ?? "")")
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popupWindows.first(where: { $0.contentView === webView }) else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        popupWindows.removeAll { $0 === window }
    }
}
