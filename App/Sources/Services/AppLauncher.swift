import AppKit
import Foundation

/// Launch and reveal (spec §7 actions). Launching a shortcut is exactly what Finder does: LaunchServices opens the
/// shortcut bundle, the launcher inside takes over.
enum AppLauncher {
    @MainActor
    static func launch(_ record: ShortcutRecord) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: record.bundleURL, configuration: configuration)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
