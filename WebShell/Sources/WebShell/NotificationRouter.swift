import DuplicatorCore
import Foundation

/// Delivery side of web notifications. `UserNotificationPoster` wraps `UNUserNotificationCenter`;
/// tests inject a fake because the real center raises outside an app bundle.
@MainActor
protocol NotificationPosting: AnyObject {
    /// Installs the click callback (it receives the delivered request identifier) and requests authorization.
    func start(onClick: @escaping @MainActor (String) -> Void)
    func post(id: UUID, title: String, body: String, tag: String?)
    func removeDelivered(id: UUID)
}

/// Bounded FIFO map from notification id to the frame that created it (mirrors the shim's newest-100 window).
struct NotificationTargets<Target> {
    let capacity: Int
    private var order: [UUID] = []
    private var targets: [UUID: Target] = [:]

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    var count: Int { targets.count }

    subscript(id: UUID) -> Target? { targets[id] }

    mutating func insert(_ target: Target, for id: UUID) {
        if targets.updateValue(target, forKey: id) == nil {
            order.append(id)
        }
        while order.count > capacity {
            targets.removeValue(forKey: order.removeFirst())
        }
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Target? {
        guard let target = targets.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return target
    }
}

/// Validates `madNotification` messages, posts them, and routes clicks back to the originating target.
@MainActor
final class NotificationRouter<Target> {
    private let poster: NotificationPosting
    private let logger: LaunchLogger
    private let bringToFront: @MainActor () -> Void
    private let dispatch: @MainActor (String, Target) -> Void
    private var targets: NotificationTargets<Target>
    private var loggedInvalidMessage = false

    init(
        poster: NotificationPosting,
        logger: LaunchLogger,
        capacity: Int = 100,
        bringToFront: @escaping @MainActor () -> Void,
        dispatch: @escaping @MainActor (String, Target) -> Void
    ) {
        self.poster = poster
        self.logger = logger
        self.bringToFront = bringToFront
        self.dispatch = dispatch
        targets = NotificationTargets(capacity: capacity)
    }

    var pendingCount: Int { targets.count }

    func start() {
        poster.start { [weak self] identifier in
            self?.click(identifier: identifier)
        }
    }

    func receive(_ body: Any, from target: Target) {
        switch WebShellMessages.notification(fromMessageBody: body) {
        case let .show(id, title, text, tag):
            targets.insert(target, for: id)
            poster.post(id: id, title: title, body: text, tag: tag)
            logger.log("notification \"\(WebShellMessages.loggableTitle(title))\"")
        case let .close(id):
            targets.remove(id)
            poster.removeDelivered(id: id)
        case nil:
            if !loggedInvalidMessage {
                loggedInvalidMessage = true
                logger.log("notification message dropped (invalid payload)")
            }
        }
    }

    /// Notification click: bring the window forward first, then tell the page which notification was clicked.
    func click(identifier: String) {
        bringToFront()
        guard let id = UUID(uuidString: identifier), let target = targets.remove(id) else {
            logger.log("notification click: page no longer holds it")
            return
        }
        dispatch(WebShellScripts.notificationClickedScript(id: id), target)
    }
}
