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
        coordinator.loadHome()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("quit")
    }
}
