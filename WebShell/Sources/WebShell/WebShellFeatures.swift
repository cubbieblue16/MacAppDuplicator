import AppKit
import DuplicatorCore

/// Wires the badge, notifications, background mode and the status item into the Task 2 shell.
@MainActor
final class WebShellFeatures {
    let policy: BackgroundModePolicy
    let badge: BadgeController
    let notifications: NotificationBridge
    private let appName: String
    private let logger: LaunchLogger
    private let showWindow: @MainActor () -> Void
    private var statusItem: StatusItemController?
    private weak var coordinator: WebViewCoordinator?

    init(
        webApp: WebAppConfig,
        hostPolicy: WebHostPolicy,
        menuBarIcon: Bool,
        appName: String,
        logger: LaunchLogger,
        poster: NotificationPosting,
        showWindow: @escaping @MainActor () -> Void
    ) {
        policy = BackgroundModePolicy(backgroundMode: webApp.backgroundMode, menuBarIcon: menuBarIcon)
        self.appName = appName
        self.logger = logger
        self.showWindow = showWindow
        badge = BadgeController(parser: BadgeTitleParser(pattern: webApp.badgeRegex), logger: logger) { label in
            NSApp.dockTile.badgeLabel = label
        }
        notifications = NotificationBridge(poster: poster, hostPolicy: hostPolicy, logger: logger) {
            WebShellFeatures.bringAppToFront(showWindow: showWindow)
        }
    }

    /// Call once from `applicationDidFinishLaunching`, before the first page load.
    func install(on coordinator: WebViewCoordinator) {
        self.coordinator = coordinator
        let showWindow = self.showWindow
        coordinator.bringToFront = { WebShellFeatures.bringAppToFront(showWindow: showWindow) }
        badge.trustedWebView = coordinator.webView
        coordinator.addMessageHandler(badge, name: WebShellScripts.badgeHandlerName)
        coordinator.addMessageHandler(notifications, name: WebShellScripts.notificationHandlerName)
        let previous = coordinator.titleDidChange
        let badge = self.badge
        coordinator.titleDidChange = { title in
            previous?(title)
            badge.titleDidChange(title)
        }
        notifications.start()
        if policy.showsStatusItem {
            let item = StatusItemController(appName: appName, icon: NSApp.applicationIconImage) {
                WebShellFeatures.bringAppToFront(showWindow: showWindow)
            }
            item.update(count: badge.count)
            badge.countDidChange = { [weak item] count in
                item?.update(count: count)
            }
            statusItem = item
        }
        logger.log("features statusItem=\(policy.showsStatusItem) background=\(policy.keepsRunningWhenWindowCloses)")
    }

    /// Window delegate hook: in background mode hide the window and drop the Dock icon instead of closing.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard policy.keepsRunningWhenWindowCloses else { return true }
        window.orderOut(nil)
        coordinator?.hidePopupWindows()
        NSApp.setActivationPolicy(.accessory)
        logger.log("window hidden; running in the menu bar")
        return false
    }

    var terminatesAfterLastWindowClosed: Bool { policy.terminatesAfterLastWindowClosed }

    /// Show menu item, Dock click and notification click all land here.
    func bringToFront() {
        WebShellFeatures.bringAppToFront(showWindow: showWindow)
    }

    static func bringAppToFront(showWindow: @MainActor () -> Void) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        showWindow()
    }
}
