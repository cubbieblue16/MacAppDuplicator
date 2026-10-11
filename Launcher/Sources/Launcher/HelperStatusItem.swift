import AppKit
import DuplicatorCore

/// The helper's menu bar item (spec §4.6): the shortcut's own icon in colour at 18 pt with the shortcut's name as the
/// tooltip, and a menu with Show <name>, New Window (only when the shortcut has a New Window command) and Quit <name>.
/// Laid out like WebShell's `StatusItemController`; the helper owns no window, so every item calls back into
/// `HelperMenuBarRunner` through a `@MainActor` closure.
@MainActor
final class HelperStatusItem: NSObject {
    static let iconPointSize: CGFloat = 18

    private let statusItem: NSStatusItem
    private let onShow: @MainActor () -> Void
    private let onNewWindow: (@MainActor () -> Void)?
    private let onQuit: @MainActor () -> Void

    init(
        name: String,
        icon: NSImage,
        onShow: @escaping @MainActor () -> Void,
        onNewWindow: (@MainActor () -> Void)?,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onShow = onShow
        self.onNewWindow = onNewWindow
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = HelperStatusItem.menuBarImage(from: icon)
            button.imagePosition = .imageOnly
            button.toolTip = name
        }
        let menu = NSMenu()
        menu.addItem(menuItem(title: HelperMenuText.show(name: name), action: #selector(showFromMenu(_:))))
        if onNewWindow != nil {
            menu.addItem(menuItem(title: HelperMenuText.newWindow, action: #selector(newWindowFromMenu(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(title: HelperMenuText.quit(name: name), action: #selector(quitFromMenu(_:))))
        statusItem.menu = menu
    }

    /// A resized copy of `icon` in colour; the original image is left untouched.
    static func menuBarImage(from icon: NSImage) -> NSImage {
        let side = NSSize(width: iconPointSize, height: iconPointSize)
        let image = icon.copy() as? NSImage ?? NSImage(size: side)
        image.size = side
        image.isTemplate = false
        return image
    }

    /// The shortcut's own icon: the `CFBundleIconFile` image in `Contents/Resources` (`BundleWriter` writes
    /// `AppIcon.icns` when the shortcut has an icon), else the icon Finder shows for the bundle.
    static func shortcutIcon(bundleURL: URL) -> NSImage {
        if let iconName = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !iconName.isEmpty {
            let fileName = (iconName as NSString).pathExtension.isEmpty ? iconName + ".icns" : iconName
            let iconURL = bundleURL
                .appending(path: "Contents/Resources", directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
            if let image = NSImage(contentsOf: iconURL) {
                return image
            }
        }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showFromMenu(_ sender: NSMenuItem) {
        onShow()
    }

    @objc private func newWindowFromMenu(_ sender: NSMenuItem) {
        onNewWindow?()
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        onQuit()
    }
}
