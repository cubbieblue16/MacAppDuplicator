import AppKit
import DuplicatorCore

/// Application delegate of a web-app shortcut. Task 3 adds the badge, notification and status-item controllers here.
@MainActor
final class WebShellAppDelegate: NSObject, NSApplicationDelegate {
    let shell: ShellConfig
    let logger: LaunchLogger
    private(set) var coordinator: WebViewCoordinator?
    private(set) var windowController: MainWindowController?
    /// Retained here: menu item targets are weak.
    private var zoomController: PageZoomController?
    /// Task 3: badge, notifications, background mode and the status item.
    private var features: WebShellFeatures?

    init(shell: ShellConfig, logger: LaunchLogger) {
        self.shell = shell
        self.logger = logger
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let coordinator = WebViewCoordinator(shell: shell, logger: logger)
        let zoom = PageZoomController(defaults: .standard, configZoom: shell.webApp.pageZoom, webView: coordinator.webView)
        let menus = MainMenu.build(appName: shell.shortcut.name, zoom: zoom)
        NSApp.mainMenu = menus.main
        NSApp.windowsMenu = menus.windows
        self.coordinator = coordinator
        zoomController = zoom
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let coordinator else { return }
        let controller = MainWindowController(coordinator: coordinator, shell: shell, logger: logger)
        windowController = controller
        logger.log(
            "config name=\(shell.shortcut.name) host=\(shell.baseURL.host() ?? "") ua=\(shell.webApp.userAgent.rawValue) "
                + "zoom=\(coordinator.webView.pageZoom) store=\(shell.webApp.dataStoreID.uuidString)"
        )
        // LaunchServices activates a normal launch; not calling NSApp.activate() keeps `activates = false` honest.
        controller.window.makeKeyAndOrderFront(nil)
        installFeatures(webApp: shell.webApp, shortcut: shell.shortcut, logger: logger, windowController: controller, coordinator: coordinator)
        coordinator.loadHome()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        features?.terminatesAfterLastWindowClosed ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let features {
            features.bringToFront()
        } else {
            windowController?.showWindow()
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("quit")
    }

    /// Task 3: badge, notifications, background mode and the status item (skeleton decisions 7, 8, 9).
    private func installFeatures(
        webApp: WebAppConfig,
        shortcut: ShortcutConfig,
        logger: LaunchLogger,
        windowController: MainWindowController,
        coordinator: WebViewCoordinator
    ) {
        let features = WebShellFeatures(
            webApp: webApp,
            hostPolicy: shell.policy,
            menuBarIcon: shortcut.menuBarIcon,
            appName: StatusItemText.appName(infoDictionary: Bundle.main.infoDictionary, fallback: shortcut.name),
            logger: logger,
            poster: UserNotificationPoster(logger: logger),
            showWindow: { [weak windowController] in windowController?.showWindow() }
        )
        features.install(on: coordinator)
        windowController.shouldClose = { [weak features] window in features?.windowShouldClose(window) ?? true }
        self.features = features
    }
}
