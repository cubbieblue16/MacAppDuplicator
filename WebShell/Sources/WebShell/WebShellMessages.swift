import Foundation

/// Pure validation of the bodies the page posts to the `madBadge` and `madNotification` handlers.
enum WebShellMessages {
    enum NotificationMessage: Equatable {
        case show(id: UUID, title: String, body: String, tag: String?)
        case close(id: UUID)
    }

    static let maxTextLength = 1_024
    static let maxLoggedTitleLength = 120

    /// `{count: n}` gives n; `{}` or `{count: null}` gives 0 (clear); anything else gives nil (drop).
    static func badgeCount(fromMessageBody body: Any) -> Int? {
        guard let dictionary = body as? [String: Any] else { return nil }
        guard let value = dictionary["count"], !(value is NSNull) else { return 0 }
        if let text = value as? String {
            guard let count = Int(text), count >= 0 else { return nil }
            return count
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let count = Int(exactly: number.doubleValue), count >= 0 else { return nil }
        return count
    }

    /// Shim payloads: `{id, title, body, tag}` shows, `{id, close: true}` closes. An id that is not a UUID drops the message.
    static func notification(fromMessageBody body: Any) -> NotificationMessage? {
        guard let dictionary = body as? [String: Any],
              let idText = dictionary["id"] as? String,
              let id = UUID(uuidString: idText) else { return nil }
        if let close = dictionary["close"] as? Bool, close {
            return .close(id: id)
        }
        guard let title = dictionary["title"] as? String else { return nil }
        let text = dictionary["body"] as? String ?? ""
        let tag = (dictionary["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .show(id: id, title: truncated(title), body: truncated(text), tag: tag.map(truncated))
    }

    /// Single-line, length-capped form of a notification title for the launch log (bodies are never logged).
    static func loggableTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(String(scalars).prefix(maxLoggedTitleLength))
    }

    private static func truncated(_ text: String) -> String {
        String(text.prefix(maxTextLength))
    }
}
