import AppKit
import DuplicatorCore

/// Logs the failure, shows a critical alert, and exits with the error's launcher exit code (spec §4.7).
/// The log lines are written before the alert so they exist even if the alert is never dismissed.
/// The spec §4.7 "Locate..." button is deferred to Phase 2 (it needs the library app's `mad://locate` handler).
@MainActor
func fail(_ error: Error, logger: LaunchLogger) -> Never {
    let code = (error as? LauncherError)?.exitCode ?? 3
    logger.log("error \(error.localizedDescription)")
    logger.log("exit \(code)")

    // A faceless process cannot show an alert, so become a regular app first.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()

    let alert = NSAlert()
    alert.messageText = "Shortcut could not start"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
    exit(code)
}
