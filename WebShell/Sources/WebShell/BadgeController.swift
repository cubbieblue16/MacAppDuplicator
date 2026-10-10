import AppKit
import DuplicatorCore
import WebKit

/// The badge count as last written by either source (page title or the `madBadge` bridge); last writer wins.
struct BadgeState: Equatable {
    private(set) var count = 0

    var badgeLabel: String? { count > 0 ? String(count) : nil }

    /// Stores `newCount` (negative values clamp to 0) and returns true when the stored count changed.
    mutating func write(_ newCount: Int) -> Bool {
        let clamped = max(0, newCount)
        guard clamped != count else { return false }
        count = clamped
        return true
    }

    /// A title without a match clears the badge (skeleton decision 7).
    static func count(fromTitle title: String, parser: BadgeTitleParser) -> Int {
        parser.count(in: title) ?? 0
    }
}

/// `madBadge` handler and title observer: drives the Dock badge and publishes the count to the status item.
@MainActor
final class BadgeController: NSObject, WKScriptMessageHandler {
    private let parser: BadgeTitleParser
    private let logger: LaunchLogger
    private let setDockBadge: @MainActor (String?) -> Void
    private var state = BadgeState()
    private var loggedInvalidMessage = false

    /// Receives the new count whenever it changes.
    var countDidChange: (@MainActor (Int) -> Void)?

    var count: Int { state.count }

    /// The only web view whose main frame may post badge counts; set by `WebShellFeatures.install`.
    weak var trustedWebView: WKWebView?

    init(parser: BadgeTitleParser, logger: LaunchLogger, setDockBadge: @escaping @MainActor (String?) -> Void) {
        self.parser = parser
        self.logger = logger
        self.setDockBadge = setDockBadge
        super.init()
        if parser.usedFallbackPattern {
            logger.log("badge pattern invalid; using default \(parser.pattern)")
        }
    }

    func titleDidChange(_ title: String) {
        write(BadgeState.count(fromTitle: title, parser: parser), source: "title")
    }

    func handleMessageBody(_ body: Any) {
        guard let count = WebShellMessages.badgeCount(fromMessageBody: body) else {
            if !loggedInvalidMessage {
                loggedInvalidMessage = true
                logger.log("badge message dropped (invalid payload)")
            }
            return
        }
        write(count, source: "page")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebShellScripts.badgeHandlerName else { return }
        guard message.frameInfo.isMainFrame, let trustedWebView, message.webView === trustedWebView else {
            if !loggedInvalidMessage {
                loggedInvalidMessage = true
                logger.log("badge message dropped (not from the main frame)")
            }
            return
        }
        handleMessageBody(message.body)
    }

    private func write(_ newCount: Int, source: String) {
        guard state.write(newCount) else { return }
        setDockBadge(state.badgeLabel)
        countDidChange?(state.count)
        logger.log("badge \(state.count) from \(source)")
    }
}
