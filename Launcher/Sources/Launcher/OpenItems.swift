import AppKit
import DuplicatorCore
import os

/// Opens a file or folder shortcut's items, then exits (spec §6). With no `openerApp` each item goes to its default
/// handler through `NSWorkspace.open(_:)`, which answers synchronously. With an `openerApp` the open is asynchronous:
/// the Launcher is a plain `main.swift` with no `NSApplication` run loop, so the main thread polls a semaphore and pumps
/// `RunLoop.main` in 50 ms slices (the same wait as `launchViaSystem`) until the completion handler signals or 10 s
/// pass. On timeout the request is already with LaunchServices, so a slow cold launch of the opener is logged and
/// the Launcher still exits 0 rather than reporting the item as missing.
@MainActor
func openItems(_ items: [URL], openerApp: URL?, logger: LaunchLogger) -> Never {
    for item in items where !FileManager.default.fileExists(atPath: item.path) {
        fail(LauncherError.fileNotFound(path: item.path), logger: logger)
    }
    for item in items {
        logger.log("open \(item.path)")
    }

    guard let openerApp else {
        for item in items where !NSWorkspace.shared.open(item) {
            logger.log("open failed: no default handler accepted \(item.path)")
            fail(LauncherError.fileNotFound(path: item.path), logger: logger)
        }
        logger.log("exit 0")
        exit(0)
    }

    logger.log("opener \(openerApp.path)")
    let done = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    NSWorkspace.shared.open(items, withApplicationAt: openerApp, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        failure.withLock { $0 = error?.localizedDescription }
        done.signal()
    }

    // The completion handler's queue is not documented, so the main thread must not block on the semaphore.
    let deadline = Date(timeIntervalSinceNow: 10)
    var completed = false
    while !completed, Date() < deadline {
        completed = done.wait(timeout: .now()) == .success
        if !completed {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    if !completed {
        logger.log("open still pending after 10 s")
    } else if let message = failure.withLock({ $0 }) {
        logger.log("open failed: \(message)")
        fail(LauncherError.fileNotFound(path: openerApp.path), logger: logger)
    }
    logger.log("exit 0")
    exit(0)
}
