import AppKit

/// Copy for the status item (skeleton decision 9).
enum StatusItemText {
    static func title(forCount count: Int) -> String {
        count > 0 ? String(count) : ""
    }

    static func showItemTitle(appName: String) -> String {
        "Show \(appName)"
    }

    static func quitItemTitle(appName: String) -> String {
        "Quit \(appName)"
    }

    /// `CFBundleName` of the shortcut bundle, or `fallback` when it is missing or empty.
    static func appName(infoDictionary: [String: Any]?, fallback: String) -> String {
        if let name = infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return fallback
    }
}

/// Menu bar item: bundle icon at 18 pt, unread count as the title, Show / Quit menu.
@MainActor
final class StatusItemController: NSObject {
    static let iconPointSize: CGFloat = 18

    private let statusItem: NSStatusItem
    private let onShow: @MainActor () -> Void

    init(appName: String, icon: NSImage, onShow: @escaping @MainActor () -> Void) {
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = StatusItemController.menuBarImage(from: icon)
            button.imagePosition = .imageLeading
            button.title = StatusItemText.title(forCount: 0)
        }
        let menu = NSMenu()
        let show = NSMenuItem(
            title: StatusItemText.showItemTitle(appName: appName),
            action: #selector(showFromMenu(_:)),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: StatusItemText.quitItemTitle(appName: appName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))
        statusItem.menu = menu
    }

    func update(count: Int) {
        statusItem.button?.title = StatusItemText.title(forCount: count)
    }

    /// A resized copy of `icon`; the original image is left untouched.
    static func menuBarImage(from icon: NSImage) -> NSImage {
        let side = NSSize(width: iconPointSize, height: iconPointSize)
        let image = icon.copy() as? NSImage ?? NSImage(size: side)
        image.size = side
        image.isTemplate = false
        return image
    }

    @objc private func showFromMenu(_ sender: NSMenuItem) {
        onShow()
    }
}
