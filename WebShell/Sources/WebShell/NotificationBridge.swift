import AppKit
import DuplicatorCore
import UserNotifications
import WebKit

/// The frame that created a notification; its click is evaluated back in that frame and content world.
struct NotificationTarget {
    weak var webView: WKWebView?
    let frame: WKFrameInfo
    let world: WKContentWorld
}

/// `madNotification` handler (skeleton decision 8).
@MainActor
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    let router: NotificationRouter<NotificationTarget>

    init(poster: NotificationPosting, logger: LaunchLogger, bringToFront: @escaping @MainActor () -> Void) {
        router = NotificationRouter(poster: poster, logger: logger, bringToFront: bringToFront) { script, target in
            guard let webView = target.webView else {
                logger.log("notification click: web view gone")
                return
            }
            webView.evaluateJavaScript(script, in: target.frame, in: target.world) { result in
                if case let .failure(error) = result {
                    logger.log("error notification click script: \(error.localizedDescription)")
                }
            }
        }
        super.init()
    }

    func start() {
        router.start()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebShellScripts.notificationHandlerName else { return }
        let target = NotificationTarget(webView: message.webView, frame: message.frameInfo, world: message.world)
        router.receive(message.body, from: target)
    }
}

/// Real delivery through `UNUserNotificationCenter`. Built only inside the shell app, never in tests.
@MainActor
final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let logger: LaunchLogger
    private var onClick: (@MainActor (String) -> Void)?

    init(center: UNUserNotificationCenter = .current(), logger: LaunchLogger) {
        self.center = center
        self.logger = logger
        super.init()
    }

    func start(onClick: @escaping @MainActor (String) -> Void) {
        self.onClick = onClick
        center.delegate = self
        let logger = self.logger
        center.requestAuthorization(options: [.alert, .badge, .sound]) { @Sendable granted, error in
            if let error {
                logger.log("error notification authorization: \(error.localizedDescription)")
            } else {
                logger.log("notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    func post(id: UUID, title: String, body: String, tag: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let tag {
            content.threadIdentifier = tag
        }
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        let logger = self.logger
        center.add(request) { @Sendable error in
            if let error {
                logger.log("error notification delivery: \(error.localizedDescription)")
            }
        }
    }

    func removeDelivered(id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                self.onClick?(identifier)
            }
        }
        completionHandler()
    }
}
