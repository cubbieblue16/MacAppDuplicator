import DuplicatorCore
import Foundation

/// Why web data was not removed.
enum WebDataRemovalError: LocalizedError, Equatable {
    /// The bundle identifier is not one App Duplicator gives a shortcut (`ShortcutConfig.bundleIdentifierPrefix` plus a slug).
    case invalidBundleIdentifier(String)
    /// The web app is running; WebKit keeps its store open until the web view is released.
    case shortcutRunning(String)

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier(let identifier):
            "“\(identifier)” is not a web app bundle identifier, so no web data was removed."
        case .shortcutRunning(let name):
            "Quit “\(name)” before removing its web data."
        }
    }
}

/// Removes the logins, cookies and cache a web app keeps in its `WKWebsiteDataStore(forIdentifier:)`.
protocol WebDataRemoving: Sendable {
    /// `bundleIdentifier` is the web app shortcut's own bundle identifier: WebKit files the store under the hosting
    /// process's bundle identifier, which for a web app is the shortcut's, never this app's. An identifier with no
    /// store is not an error.
    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws
}

/// Deletes `<webKitRoot>/<bundle id>/WebsiteDataStore/<store id>`, the one directory WebKit keeps per identified store
/// (Cookies, NetworkCache, LocalStorage and the rest). Calling `WKWebsiteDataStore.remove(forIdentifier:)` from this
/// app would resolve to this app's own bundle identifier and miss the shell's store (Task 6 Deviation 1).
struct WebKitWebDataRemover: WebDataRemoving {
    let webKitRoot: URL

    init(webKitRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/WebKit", directoryHint: .isDirectory)) {
        self.webKitRoot = webKitRoot
    }

    /// True for `com.mikekuta.appduplicator.` followed by a slug: lowercase ASCII letters, digits and hyphens.
    static func isShellBundleIdentifier(_ identifier: String) -> Bool {
        let prefix = ShortcutConfig.bundleIdentifierPrefix
        guard identifier.hasPrefix(prefix) else { return false }
        let slug = identifier.dropFirst(prefix.count)
        return !slug.isEmpty && slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws {
        guard Self.isShellBundleIdentifier(bundleIdentifier) else {
            throw WebDataRemovalError.invalidBundleIdentifier(bundleIdentifier)
        }
        let root = webKitRoot
        let storeName = identifier.uuidString.lowercased()
        try await Task.detached(priority: .userInitiated) {
            try Self.removeStore(named: storeName, bundleIdentifier: bundleIdentifier, in: root)
        }.value
    }

    private static func removeStore(named storeName: String, bundleIdentifier: String, in root: URL) throws {
        let fileManager = FileManager.default
        let stores = root.appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "WebsiteDataStore", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: stores.path) else { return }
        for entry in try fileManager.contentsOfDirectory(at: stores, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.lowercased() == storeName {
            try fileManager.removeItem(at: entry)
        }
    }
}
