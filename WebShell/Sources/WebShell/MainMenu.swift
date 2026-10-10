import AppKit
import DuplicatorCore
import WebKit

/// Drives `webView.pageZoom` from the View menu and keeps the live value in the shell's own defaults under
/// `MADPageZoom` (skeleton decision 5: the signed bundle's Info.plist is never written). Config `pageZoom` is
/// only the initial value; a stored value wins.
@MainActor
final class PageZoomController: NSObject {
    static let defaultsKey = "MADPageZoom"
    static let step = 0.1

    private let defaults: UserDefaults
    private let webView: WKWebView

    init(defaults: UserDefaults, configZoom: Double, webView: WKWebView) {
        self.defaults = defaults
        self.webView = webView
        super.init()
        let stored = defaults.object(forKey: Self.defaultsKey) as? Double
        webView.pageZoom = CGFloat(WebAppConfig.clampedZoom(stored ?? configZoom))
    }

    @objc func zoomIn(_ sender: Any?) {
        apply(Double(webView.pageZoom) + Self.step)
    }

    @objc func zoomOut(_ sender: Any?) {
        apply(Double(webView.pageZoom) - Self.step)
    }

    @objc func actualSize(_ sender: Any?) {
        apply(1.0)
    }

    private func apply(_ value: Double) {
        let zoom = WebAppConfig.clampedZoom((value * 100).rounded() / 100)
        webView.pageZoom = CGFloat(zoom)
        defaults.set(zoom, forKey: Self.defaultsKey)
    }
}

/// Programmatic main menu (skeleton decision 2). The Edit menu is required for Cmd-C/V/X/A inside WKWebView.
@MainActor
enum MainMenu {
    static func build(appName: String, zoom: PageZoomController) -> (main: NSMenu, windows: NSMenu) {
        let main = NSMenu()

        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        let view = NSMenu(title: "View")
        let zoomIn = view.addItem(withTitle: "Zoom In", action: #selector(PageZoomController.zoomIn(_:)), keyEquivalent: "=")
        zoomIn.target = zoom
        let zoomOut = view.addItem(withTitle: "Zoom Out", action: #selector(PageZoomController.zoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = zoom
        let actualSize = view.addItem(withTitle: "Actual Size",
                                      action: #selector(PageZoomController.actualSize(_:)), keyEquivalent: "0")
        actualSize.target = zoom
        main.addItem(submenuItem(view))

        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenuItem(windows))

        return (main, windows)
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
