import DuplicatorCore
import Foundation
import Synchronization
@testable import MacAppDuplicator

/// A web-app config the way the wizard builds one (skeleton decision 4): empty target, Dock Shortcut, data disabled.
func makeWebShortcutConfig(
    name: String = "Chat", url: String = "https://chat.example.com/", dataStoreID: UUID = UUID(),
    menuBarIcon: Bool = false, backgroundMode: Bool = false
) -> ShortcutConfig {
    let slug = ShortcutConfig.slug(for: name)
    return ShortcutConfig(
        kind: .webApp, name: name, slug: slug, bundleIdentifier: ShortcutConfig.bundleIdentifier(forSlug: slug),
        targetPath: "", targetBundleIdentifier: "", launchMode: .dockShortcut, dataMode: .disabled,
        menuBarIcon: menuBarIcon, iconMode: .copied,
        webApp: WebAppConfig(url: url, dataStoreID: dataStoreID, backgroundMode: backgroundMode)
    )
}

struct FakeRemovalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records every removal request and optionally fails; never touches `~/Library/WebKit`.
final class FakeWebDataRemover: WebDataRemoving, Sendable {
    struct Call: Equatable, Sendable {
        let identifier: UUID
        let bundleIdentifier: String
    }

    private let recorded = Mutex<[Call]>([])
    private let failureMessage: String?

    init(failureMessage: String? = nil) {
        self.failureMessage = failureMessage
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func removeWebData(identifier: UUID, bundleIdentifier: String) async throws {
        recorded.withLock { $0.append(Call(identifier: identifier, bundleIdentifier: bundleIdentifier)) }
        if let failureMessage { throw FakeRemovalError(message: failureMessage) }
    }
}

/// The standardized bundle paths a stub `RunningShortcutMonitor` probe reports as running.
final class RunningPaths: Sendable {
    private let storage = Mutex<Set<String>>([])

    func set(_ paths: Set<String>) { storage.withLock { $0 = paths } }
    var paths: Set<String> { storage.withLock { $0 } }
}

/// The one place the web tests construct an `AppState` (assumption A1: Task 4 adds `webShellBinary:`).
@MainActor
func makeWebTestAppState(
    settings: AppSettings, library: ShortcutLibrary, launcher: URL, webShell: URL, remover: any WebDataRemoving
) -> AppState {
    let state = AppState(settings: settings, library: library, launcherBinary: launcher, webShellBinary: webShell)
    state.webDataRemover = remover
    return state
}
