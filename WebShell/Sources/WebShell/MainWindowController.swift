import AppKit
import DuplicatorCore
import WebKit

/// The shortcut's main window: hosts the web view, mirrors the page title and shows an inline load-error view.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "MADMainWindow"

    let window: NSWindow
    private let coordinator: WebViewCoordinator
    private let shell: ShellConfig
    private let errorView: NSStackView
    private let errorDetail: NSTextField
    private let retryButton: NSButton
    private var retryURL: URL?
    private var titleObservation: NSKeyValueObservation?

    init(coordinator: WebViewCoordinator, shell: ShellConfig, logger: LaunchLogger) {
        self.coordinator = coordinator
        self.shell = shell
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let headline = NSTextField(labelWithString: "This page could not be loaded")
        headline.font = .boldSystemFont(ofSize: 17)
        errorDetail = NSTextField(wrappingLabelWithString: "")
        errorDetail.alignment = .center
        errorDetail.preferredMaxLayoutWidth = 420
        retryButton = NSButton(title: "Retry", target: nil, action: nil)
        retryButton.keyEquivalent = "\r"
        errorView = NSStackView(views: [headline, errorDetail, retryButton])
        super.init()

        retryButton.target = self
        retryButton.action = #selector(retryLoad(_:))
        errorView.orientation = .vertical
        errorView.alignment = .centerX
        errorView.spacing = 12
        errorView.isHidden = true

        let container = NSView()
        let webView = coordinator.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        errorView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(errorView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            errorView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            errorView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 320)
        window.title = shell.shortcut.name
        window.contentView = container
        window.delegate = self
        window.center()
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            logger.log("error frame autosave name \(Self.frameAutosaveName) already in use")
        }

        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateTitle()
            }
        }
        coordinator.provisionalLoadDidFail = { [weak self] error in
            self?.showError(error)
        }
        coordinator.navigationDidCommit = { [weak self] in
            self?.hideError()
        }
    }

    /// Brings the main window to the front (Dock reopen, status item and notification clicks).
    func showWindow() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Background mode hides the window instead of closing it (see WebShellFeatures.windowShouldClose).
    var shouldClose: (@MainActor (NSWindow) -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose?(sender) ?? true
    }

    func showError(_ error: Error) {
        retryURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        errorDetail.stringValue = error.localizedDescription
        coordinator.webView.isHidden = true
        errorView.isHidden = false
    }

    func hideError() {
        errorView.isHidden = true
        coordinator.webView.isHidden = false
    }

    @objc private func retryLoad(_ sender: Any?) {
        errorDetail.stringValue = "Retrying…"
        coordinator.resetCrashCount()
        coordinator.load(retryURL ?? shell.baseURL)
    }

    private func updateTitle() {
        let pageTitle = coordinator.webView.title ?? ""
        window.title = pageTitle.isEmpty ? shell.shortcut.name : pageTitle
    }
}
