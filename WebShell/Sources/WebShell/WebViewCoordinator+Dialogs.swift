import AppKit
import WebKit

/// Copy and response mapping for page dialogs, kept free of UI so it can be unit-tested.
enum DialogPresentation {
    struct AlertText: Equatable {
        let title: String
        let informativeText: String
    }

    static let fallbackTitle = "This page"
    static let okButtonTitle = "OK"
    static let cancelButtonTitle = "Cancel"
    static let textFieldWidth: CGFloat = 240

    /// The host of the frame that opened the dialog is the alert title; the page's message is the informative text.
    static func alertText(message: String, host: String) -> AlertText {
        AlertText(title: host.isEmpty ? fallbackTitle : host, informativeText: message)
    }

    /// Only the first button (OK) confirms.
    static func confirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// The typed text for OK, nil for Cancel.
    static func textInputResult(_ response: NSApplication.ModalResponse, text: String) -> String? {
        confirmed(response) ? text : nil
    }

    /// The chosen URLs for OK, nil for Cancel or a panel that failed to display.
    static func openPanelResult(_ response: NSApplication.ModalResponse, urls: [URL]) -> [URL]? {
        response == .OK ? urls : nil
    }
}

/// JavaScript alert / confirm / prompt and `<input type="file">`. Task 2's `WebViewCoordinator` is the web view's
/// `WKUIDelegate` but leaves these four methods unimplemented, so WebKit would otherwise skip the dialogs silently.
extension WebViewCoordinator {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        present(alert, in: webView) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        alert.addButton(withTitle: DialogPresentation.cancelButtonTitle)
        present(alert, in: webView) { response in
            completionHandler(DialogPresentation.confirmed(response))
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let alert = makeAlert(message: prompt, frame: frame)
        alert.addButton(withTitle: DialogPresentation.okButtonTitle)
        alert.addButton(withTitle: DialogPresentation.cancelButtonTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: DialogPresentation.textFieldWidth, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, in: webView) { response in
            completionHandler(DialogPresentation.textInputResult(response, text: field.stringValue))
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(DialogPresentation.openPanelResult(response, urls: panel.urls))
            }
        } else {
            completionHandler(DialogPresentation.openPanelResult(panel.runModal(), urls: panel.urls))
        }
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let text = DialogPresentation.alertText(message: message, host: frame.securityOrigin.host)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.informativeText
        return alert
    }

    /// Sheet on the web view's window; app-modal when the web view has no window.
    private func present(
        _ alert: NSAlert,
        in webView: WKWebView,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in
                completion(response)
            }
        } else {
            completion(alert.runModal())
        }
    }
}
